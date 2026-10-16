# webapp-mcp

A .NET 10 [Model Context Protocol](https://modelcontextprotocol.io) (MCP) server, hosted on Azure App Service, that
can be added to Microsoft 365 Copilot as a
[custom federated connector](https://learn.microsoft.com/microsoft-365/copilot/connectors/set-up-custom-federated-connectors)
using **Microsoft Entra SSO**. It receives the signed-in user's delegated token and returns the user's profile
from Microsoft Graph `/me` using the On-Behalf-Of flow.

- ASP.NET Core + [`ModelContextProtocol.AspNetCore`](https://www.nuget.org/packages/ModelContextProtocol.AspNetCore)
  (Streamable HTTP, stateless) with MCP authorization (Protected Resource Metadata, RFC 9728)
- [`Microsoft.Identity.Web`](https://www.nuget.org/packages/Microsoft.Identity.Web) for token validation and OBO
- Secretless in Azure: user-assigned managed identity as a federated identity credential of the Entra app

## Tools

| Tool | Description |
| --- | --- |
| `get_my_profile` | Signed-in user's profile from Microsoft Graph `GET /v1.0/me`. |
| `get_my_token_claims` | Identity and calling client app from the validated access token. |

## Repository layout

| Path | Description |
| --- | --- |
| [src/webapp-mcp](src/webapp-mcp) | MCP server (`/mcp`) |
| [deploy/setup-entra.ps1](deploy/setup-entra.ps1) | Creates/updates the Entra app registration (scope, pre-authorized clients, redirect URI, Graph consent) |
| [deploy/deploy-appservice.ps1](deploy/deploy-appservice.ps1) | Creates the App Service + managed identity in the current `az` subscription and deploys the app |
| [deploy/set-user-secrets.ps1](deploy/set-user-secrets.ps1) | Stores local development settings (tenant, client ID, audiences, client secret) in .NET user secrets |
| [deploy/get-token.ps1](deploy/get-token.ps1) | Gets a delegated token via Azure CLI for local testing |
| [.mcp.json](.mcp.json) | GitHub Copilot CLI configuration (local server) |
| [.vscode/mcp.json](.vscode/mcp.json) | VS Code configuration (local and Azure) |
| [docs/setup.md](docs/setup.md) | Full setup guide (Azure, Teams Developer Portal, Microsoft 365 admin center, local testing) |

## Quick start

```powershell
az login
./deploy/setup-entra.ps1 -CreateLocalDevSecret   # 1. Entra app registration
./deploy/deploy-appservice.ps1                   # 2. App Service + deployment
# 3. Teams Developer Portal: Tools > Microsoft Entra SSO client ID registration
# 4. ./deploy/setup-entra.ps1 -AdditionalIdentifierUris "<Application ID URI>"; ./deploy/deploy-appservice.ps1 -SkipBuild
# 5. Microsoft 365 admin center: Copilot > Connectors > Create a new connector > Connect to MCP server
```

Local test with GitHub Copilot CLI (settings come from .NET user secrets, not from `appsettings.json`):

```powershell
./deploy/set-user-secrets.ps1 -Show     # verify local settings (setup-entra.ps1 already stored them)
dotnet run --project src/webapp-mcp     # terminal 1
. ./deploy/get-token.ps1; copilot       # terminal 2
```

See [docs/setup.md](docs/setup.md) for step-by-step instructions.
