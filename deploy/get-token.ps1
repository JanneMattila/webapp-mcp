#Requires -Version 7.0
<#
.SYNOPSIS
    Gets a delegated access token for webapp-mcp using Azure CLI and stores it in $env:WEBAPP_MCP_TOKEN.

.DESCRIPTION
    Used for local testing with GitHub Copilot CLI (.mcp.json sends "Authorization: Bearer ${WEBAPP_MCP_TOKEN}").
    Azure CLI is pre-authorized for the access_as_user scope by setup-entra.ps1, so no consent prompt is shown.

    Dot-source the script so that the environment variable is set in your current shell:

        . ./deploy/get-token.ps1
        copilot

    Tokens are valid for about an hour; re-run the script and restart Copilot CLI when it expires.
#>
[CmdletBinding()]
param(
    [string] $EntraSettingsFile = (Join-Path $PSScriptRoot "entra-app.settings.json")
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $EntraSettingsFile)) {
    throw "Entra settings file '$EntraSettingsFile' not found. Run ./deploy/setup-entra.ps1 first."
}
$entra = Get-Content $EntraSettingsFile -Raw | ConvertFrom-Json

$token = az account get-access-token --tenant $entra.tenantId --scope $entra.scope --query accessToken -o tsv
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token)) {
    throw "Failed to get an access token for $($entra.scope). Make sure 'az login' is done and setup-entra.ps1 pre-authorized Azure CLI."
}

$env:WEBAPP_MCP_TOKEN = $token.Trim()
Write-Host "WEBAPP_MCP_TOKEN set for scope $($entra.scope) (valid ~1 hour)." -ForegroundColor Green

if ($MyInvocation.InvocationName -ne '.') {
    Write-Warning "Run this script dot-sourced ('. ./deploy/get-token.ps1') so the variable stays in your shell."
}
