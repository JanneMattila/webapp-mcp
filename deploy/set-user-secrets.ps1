#Requires -Version 7.0
<#
.SYNOPSIS
    Stores the webapp-mcp local development configuration in dotnet user-secrets.

.DESCRIPTION
    User secrets live outside the repository (%APPDATA%\Microsoft\UserSecrets\<UserSecretsId>\secrets.json on
    Windows, ~/.microsoft/usersecrets/<UserSecretsId>/secrets.json on Linux/macOS) and are loaded automatically
    when the app runs with ASPNETCORE_ENVIRONMENT=Development (the default launch profiles). This keeps tenant IDs,
    client IDs and the client secret out of the source-controlled appsettings*.json files.

    Values not passed as parameters are read from deploy/entra-app.settings.json (written by setup-entra.ps1).
    The tenant ID falls back to the current Azure CLI context.

    Secrets are piped to 'dotnet user-secrets set' as JSON on standard input, so the client secret never
    appears on a command line. Other existing user secrets are preserved.

.EXAMPLE
    # Use the values produced by setup-entra.ps1
    ./deploy/set-user-secrets.ps1

.EXAMPLE
    # Existing app registration, type the client secret at a hidden prompt
    ./deploy/set-user-secrets.ps1 -TenantId <tenant-id> -ClientId <client-id> -PromptClientSecret

.EXAMPLE
    # Create a new 90-day client secret on the app registration and store it
    ./deploy/set-user-secrets.ps1 -CreateClientSecret

.EXAMPLE
    # Show the configured values (client secret masked)
    ./deploy/set-user-secrets.ps1 -Show
#>
[CmdletBinding(DefaultParameterSetName = "Set")]
param(
    [Parameter(ParameterSetName = "Set")]
    [string] $TenantId,

    [Parameter(ParameterSetName = "Set")]
    [string] $ClientId,

    # Additional accepted token audiences, e.g. the Teams Developer Portal Application ID URI.
    # Replaces any previously stored audiences. Pass @() to remove them.
    [Parameter(ParameterSetName = "Set")]
    [string[]] $Audiences,

    [Parameter(ParameterSetName = "Set")]
    [securestring] $ClientSecret,

    [Parameter(ParameterSetName = "Set")]
    [switch] $PromptClientSecret,

    # Creates a new client secret on the app registration (az ad app credential reset --append).
    [Parameter(ParameterSetName = "Set")]
    [switch] $CreateClientSecret,

    [Parameter(ParameterSetName = "Set")]
    [ValidateRange(1, 730)]
    [int] $ClientSecretDays = 90,

    [Parameter(ParameterSetName = "Show")]
    [switch] $Show,

    [string] $EntraSettingsFile = (Join-Path $PSScriptRoot "entra-app.settings.json")
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$ProjectPath = Join-Path $PSScriptRoot ".." "src" "webapp-mcp" "webapp-mcp.csproj"

function Get-UserSecrets {
    $output = (& dotnet user-secrets list --json --project $ProjectPath | Out-String)
    if ($LASTEXITCODE -ne 0) { throw "dotnet user-secrets list failed." }
    $json = [regex]::Match($output, '(?s)//BEGIN\s*(.*?)\s*//END').Groups[1].Value
    $secrets = [ordered]@{}
    if (-not [string]::IsNullOrWhiteSpace($json)) {
        ($json | ConvertFrom-Json -AsHashtable).GetEnumerator() | Sort-Object Name | ForEach-Object { $secrets[$_.Name] = $_.Value }
    }
    return $secrets
}

function Show-UserSecrets {
    $secrets = Get-UserSecrets
    if ($secrets.Count -eq 0) {
        Write-Host "  (no user secrets configured)"
        return
    }
    foreach ($key in $secrets.Keys) {
        $value = if ($key -match 'Secret|Password|Key$') { "********" } else { $secrets[$key] }
        Write-Host "  $key = $value"
    }
}

if ($Show) {
    Write-Host "User secrets for webapp-mcp:" -ForegroundColor Cyan
    Show-UserSecrets
    return
}

# --- Resolve values ------------------------------------------------------------
$entra = $null
if (Test-Path $EntraSettingsFile) {
    $entra = Get-Content $EntraSettingsFile -Raw | ConvertFrom-Json
}

if ([string]::IsNullOrWhiteSpace($TenantId)) {
    $TenantId = if ($entra) { $entra.tenantId } else { (az account show --query tenantId -o tsv) }
}
if ([string]::IsNullOrWhiteSpace($ClientId) -and $entra) {
    $ClientId = $entra.clientId
}
if (-not $PSBoundParameters.ContainsKey("Audiences") -and $entra) {
    $Audiences = @($entra.additionalAudiences)
}

if ([string]::IsNullOrWhiteSpace($TenantId) -or [string]::IsNullOrWhiteSpace($ClientId)) {
    throw "TenantId and ClientId are required. Pass -TenantId/-ClientId or run ./deploy/setup-entra.ps1 first."
}

if ($PromptClientSecret) {
    $ClientSecret = Read-Host -Prompt "Client secret for app $ClientId" -AsSecureString
}

if ($CreateClientSecret) {
    Write-Host "Creating a $ClientSecretDays-day client secret on app $ClientId..." -ForegroundColor Cyan
    $endDate = (Get-Date).ToUniversalTime().AddDays($ClientSecretDays).ToString("yyyy-MM-dd")
    $password = az ad app credential reset --id $ClientId --append --display-name "webapp-mcp-local-dev" --end-date $endDate --query password -o tsv
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($password)) { throw "Failed to create a client secret." }
    $ClientSecret = ConvertTo-SecureString ($password | Out-String).Trim() -AsPlainText -Force
    $password = $null
}

# --- Build the new values --------------------------------------------------------
$existing = Get-UserSecrets
$keysToRemove = [System.Collections.Generic.List[string]]::new()
$values = [ordered]@{
    "AzureAd:TenantId" = $TenantId.Trim()
    "AzureAd:ClientId" = $ClientId.Trim()
}

if ($null -ne $Audiences) {
    $cleanAudiences = @($Audiences | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() } | Select-Object -Unique)
    for ($i = 0; $i -lt $cleanAudiences.Count; $i++) {
        $values["AzureAd:Audiences:$i"] = $cleanAudiences[$i]
    }
    $existing.Keys | Where-Object { $_ -match '^AzureAd:Audiences:\d+$' -and -not $values.Contains($_) } | ForEach-Object { $keysToRemove.Add($_) }
}

if ($null -ne $ClientSecret) {
    $values["AzureAd:ClientCredentials:0:SourceType"] = "ClientSecret"
    $values["AzureAd:ClientCredentials:0:ClientSecret"] = [System.Net.NetworkCredential]::new("", $ClientSecret).Password
    $existing.Keys | Where-Object { $_ -match '^AzureAd:ClientCredentials:' -and -not $values.Contains($_) } | ForEach-Object { $keysToRemove.Add($_) }
}

# --- Write ---------------------------------------------------------------------------
foreach ($key in $keysToRemove) {
    & dotnet user-secrets remove $key --project $ProjectPath | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "dotnet user-secrets remove $key failed." }
}

# Piped via stdin so that the client secret isn't visible in process command lines.
$values | ConvertTo-Json -Compress | & dotnet user-secrets set --project $ProjectPath | Out-Null
$values = $null
if ($LASTEXITCODE -ne 0) { throw "dotnet user-secrets set failed." }

Write-Host "User secrets for webapp-mcp updated:" -ForegroundColor Green
Show-UserSecrets

$hasCredential = (Get-UserSecrets).Keys -contains "AzureAd:ClientCredentials:0:ClientSecret"
if (-not $hasCredential) {
    Write-Host ""
    Write-Warning "No client secret configured. Token validation works, but get_my_profile (On-Behalf-Of to Microsoft Graph) needs one: re-run with -CreateClientSecret or -PromptClientSecret."
}
