#Requires -Version 7.0
<#
.SYNOPSIS
    Creates an Azure App Service (Linux, .NET 10) in the current Azure CLI subscription and deploys webapp-mcp.

.DESCRIPTION
    Idempotent. Run deploy/setup-entra.ps1 first.

    Creates/updates:
      * Resource group
      * User-assigned managed identity, attached to the web app
      * Linux App Service plan + web app (DOTNETCORE:10.0, HTTPS only, TLS 1.2, FTPS disabled)
      * App settings for Microsoft.Identity.Web (tenant, client id, audiences, managed identity credential)
      * Federated identity credential on the Entra app registration that trusts the managed identity,
        so the On-Behalf-Of flow to Microsoft Graph works without any client secret
    Then builds (dotnet publish), zip-deploys and smoke-tests the app.

.EXAMPLE
    ./deploy/deploy-appservice.ps1

.EXAMPLE
    ./deploy/deploy-appservice.ps1 -ResourceGroupName rg-webapp-mcp -Location westeurope -Sku P0v3
#>
[CmdletBinding()]
param(
    [string] $ResourceGroupName = "rg-webapp-mcp",

    [string] $Location = "swedencentral",

    # Globally unique web app name. Defaults to webapp-mcp-<hash of subscription and resource group>.
    [string] $AppServiceName,

    [string] $AppServicePlanName = "asp-webapp-mcp",

    [string] $ManagedIdentityName = "id-webapp-mcp",

    [string] $Sku = "B1",

    [switch] $SkipBuild,

    [string] $EntraSettingsFile = (Join-Path $PSScriptRoot "entra-app.settings.json"),

    [string] $SettingsFile = (Join-Path $PSScriptRoot "appservice.settings.json")
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$ProjectPath = Join-Path $PSScriptRoot ".." "src" "webapp-mcp" "webapp-mcp.csproj"
$PublishDir = Join-Path $PSScriptRoot ".." "artifacts" "publish"
$PackagePath = Join-Path $PSScriptRoot ".." "artifacts" "webapp-mcp.zip"
$FederatedCredentialName = "webapp-mcp-managed-identity"

function Invoke-Az {
    $output = & az @args
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed (exit code $LASTEXITCODE): az $($args -join ' ')"
    }
    return $output
}

function Invoke-AzJson {
    $text = ((Invoke-Az @args) | Out-String).Trim()
    if ([string]::IsNullOrEmpty($text)) { return $null }
    return $text | ConvertFrom-Json -Depth 50
}

# ---------------------------------------------------------------------------
if (-not (Test-Path $EntraSettingsFile)) {
    throw "Entra settings file '$EntraSettingsFile' not found. Run ./deploy/setup-entra.ps1 first."
}
$entra = Get-Content $EntraSettingsFile -Raw | ConvertFrom-Json

$account = Invoke-AzJson account show -o json
if ($account.tenantId -ne $entra.tenantId) {
    throw "Azure CLI is signed in to tenant $($account.tenantId) but the Entra app is in tenant $($entra.tenantId)."
}

if ([string]::IsNullOrWhiteSpace($AppServiceName)) {
    $hashInput = [System.Text.Encoding]::UTF8.GetBytes("$($account.id)/$ResourceGroupName".ToLowerInvariant())
    $hash = [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($hashInput)).Substring(0, 8).ToLowerInvariant()
    $AppServiceName = "webapp-mcp-$hash"
}

Write-Host "Subscription : $($account.name) ($($account.id))" -ForegroundColor Cyan
Write-Host "Web app      : $AppServiceName in $ResourceGroupName ($Location)" -ForegroundColor Cyan

# --- Resource group ------------------------------------------------------------
Write-Host "Ensuring resource group..." -ForegroundColor Cyan
Invoke-Az group create --name $ResourceGroupName --location $Location -o none

# --- User-assigned managed identity ----------------------------------------------
Write-Host "Ensuring user-assigned managed identity '$ManagedIdentityName'..." -ForegroundColor Cyan
$identity = Invoke-AzJson identity create --resource-group $ResourceGroupName --name $ManagedIdentityName --location $Location -o json

# --- App Service plan + web app ------------------------------------------------------
Write-Host "Ensuring App Service plan '$AppServicePlanName' ($Sku, Linux)..." -ForegroundColor Cyan
Invoke-Az appservice plan create --resource-group $ResourceGroupName --name $AppServicePlanName --location $Location --is-linux --sku $Sku -o none

$existingApp = ((Invoke-Az webapp list --resource-group $ResourceGroupName --query "[?name=='$AppServiceName'].name" -o tsv) | Out-String).Trim()
if ([string]::IsNullOrEmpty($existingApp)) {
    Write-Host "Creating web app '$AppServiceName'..." -ForegroundColor Cyan
    Invoke-Az webapp create --resource-group $ResourceGroupName --plan $AppServicePlanName --name $AppServiceName `
        --runtime "DOTNETCORE:10.0" --assign-identity $identity.id -o none
}
else {
    Write-Host "Web app '$AppServiceName' already exists, updating..." -ForegroundColor Cyan
}

Invoke-Az webapp identity assign --resource-group $ResourceGroupName --name $AppServiceName --identities $identity.id -o none
Invoke-Az webapp update --resource-group $ResourceGroupName --name $AppServiceName --https-only true -o none

$configArgs = @("--min-tls-version", "1.2", "--ftps-state", "Disabled", "--http20-enabled", "true")
if ($Sku -notmatch '^(F1|D1|FREE|SHARED)$') {
    $configArgs += @("--always-on", "true")
}
Invoke-Az webapp config set --resource-group $ResourceGroupName --name $AppServiceName @configArgs -o none

$hostName = ((Invoke-Az webapp show --resource-group $ResourceGroupName --name $AppServiceName --query defaultHostName -o tsv) | Out-String).Trim()
$baseUrl = "https://$hostName"
$mcpUrl = "$baseUrl/mcp"

# --- App settings -------------------------------------------------------------------
Write-Host "Configuring app settings..." -ForegroundColor Cyan
$appSettings = @(
    "ASPNETCORE_FORWARDEDHEADERS_ENABLED=true"
    "SCM_DO_BUILD_DURING_DEPLOYMENT=false"
    "AzureAd__Instance=https://login.microsoftonline.com/"
    "AzureAd__TenantId=$($entra.tenantId)"
    "AzureAd__ClientId=$($entra.clientId)"
    "AzureAd__ClientCredentials__0__SourceType=SignedAssertionFromManagedIdentity"
    "AzureAd__ClientCredentials__0__ManagedIdentityClientId=$($identity.clientId)"
    "Mcp__Scope=$($entra.scopeName)"
)
$audiences = @($entra.additionalAudiences | Where-Object { $_ })
for ($i = 0; $i -lt $audiences.Count; $i++) {
    $appSettings += "AzureAd__Audiences__$i=$($audiences[$i])"
}
Invoke-Az webapp config appsettings set --resource-group $ResourceGroupName --name $AppServiceName --settings @appSettings -o none

# --- Federated identity credential (managed identity -> Entra app) -----------------------
Write-Host "Ensuring federated identity credential on the Entra app (secretless On-Behalf-Of)..." -ForegroundColor Cyan
$ficFile = New-TemporaryFile
try {
    [ordered]@{
        name        = $FederatedCredentialName
        issuer      = "https://login.microsoftonline.com/$($entra.tenantId)/v2.0"
        subject     = $identity.principalId
        audiences   = @("api://AzureADTokenExchange")
        description = "Allows the App Service managed identity '$ManagedIdentityName' to act as the webapp-mcp app."
    } | ConvertTo-Json | Set-Content -Path $ficFile -Encoding utf8NoBOM

    $fics = @(Invoke-AzJson ad app federated-credential list --id $entra.objectId -o json)
    $fic = $fics | Where-Object { $_ -and $_.name -eq $FederatedCredentialName } | Select-Object -First 1
    if ($null -eq $fic) {
        Invoke-Az ad app federated-credential create --id $entra.objectId --parameters "@$ficFile" -o none
    }
    elseif ($fic.subject -ne $identity.principalId) {
        Invoke-Az ad app federated-credential update --id $entra.objectId --federated-credential-id $fic.id --parameters "@$ficFile" -o none
    }
}
finally {
    Remove-Item $ficFile -ErrorAction SilentlyContinue
}

# --- Build and deploy --------------------------------------------------------------
if (-not $SkipBuild) {
    Write-Host "Publishing application..." -ForegroundColor Cyan
    if (Test-Path $PublishDir) { Remove-Item $PublishDir -Recurse -Force }
    & dotnet publish $ProjectPath --configuration Release --output $PublishDir
    if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed." }

    if (Test-Path $PackagePath) { Remove-Item $PackagePath -Force }
    Compress-Archive -Path (Join-Path $PublishDir "*") -DestinationPath $PackagePath
}

if (-not (Test-Path $PackagePath)) {
    throw "Deployment package '$PackagePath' not found. Run without -SkipBuild."
}

Write-Host "Deploying package to App Service..." -ForegroundColor Cyan
Invoke-Az webapp deploy --resource-group $ResourceGroupName --name $AppServiceName --src-path $PackagePath --type zip -o none

# --- Smoke test ---------------------------------------------------------------------
Write-Host "Smoke testing $baseUrl ..." -ForegroundColor Cyan
$healthy = $false
for ($attempt = 1; $attempt -le 12 -and -not $healthy; $attempt++) {
    try {
        $response = Invoke-WebRequest -Uri $baseUrl -UseBasicParsing -TimeoutSec 30
        $healthy = $response.StatusCode -eq 200
    }
    catch {
        Start-Sleep -Seconds 10
    }
}
if (-not $healthy) {
    Write-Warning "The web app did not respond with 200 OK yet. Check logs: az webapp log tail -g $ResourceGroupName -n $AppServiceName"
}
else {
    $mcpResponse = Invoke-WebRequest -Uri $mcpUrl -Method Post -ContentType "application/json" -Body '{}' -SkipHttpErrorCheck -UseBasicParsing
    $challenge = $mcpResponse.Headers["WWW-Authenticate"]
    Write-Host "  GET  $baseUrl -> 200"
    Write-Host "  POST $mcpUrl (anonymous) -> $([int]$mcpResponse.StatusCode) $challenge"
}

# --- Output -----------------------------------------------------------------------
[ordered]@{
    subscriptionId          = $account.id
    resourceGroupName       = $ResourceGroupName
    appServiceName          = $AppServiceName
    baseUrl                 = $baseUrl
    mcpUrl                  = $mcpUrl
    managedIdentityClientId = $identity.clientId
} | ConvertTo-Json | Set-Content -Path $SettingsFile -Encoding utf8NoBOM

Write-Host ""
Write-Host "Deployment complete." -ForegroundColor Green
Write-Host "  MCP endpoint            : $mcpUrl"
Write-Host "  Protected resource meta : $baseUrl/.well-known/oauth-protected-resource/mcp"
Write-Host ""
Write-Host "Teams Developer Portal > Tools > Microsoft Entra SSO client ID registration:" -ForegroundColor Yellow
Write-Host "  Base URL  : $mcpUrl"
Write-Host "  Client ID : $($entra.clientId)"
Write-Host "  Scope     : $($entra.scope)"
Write-Host "Then add the generated Application ID URI with:" -ForegroundColor Yellow
Write-Host "  ./deploy/setup-entra.ps1 -AdditionalIdentifierUris '<Application ID URI>'; ./deploy/deploy-appservice.ps1 -SkipBuild"
