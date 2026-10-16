using System.ComponentModel;
using System.Net.Http.Headers;
using System.Security.Claims;
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.Identity.Abstractions;
using Microsoft.Identity.Client;
using Microsoft.Identity.Web;
using ModelContextProtocol;
using ModelContextProtocol.Server;

namespace WebAppMcp.Tools;

[McpServerToolType]
public sealed partial class UserProfileTools(
    IHttpContextAccessor httpContextAccessor,
    IAuthorizationHeaderProvider authorizationHeaderProvider,
    IHttpClientFactory httpClientFactory,
    ILogger<UserProfileTools> logger)
{
    public const string GraphClientName = "graph";

    private const string DefaultMeProperties =
        "id,displayName,givenName,surname,mail,userPrincipalName,jobTitle,officeLocation,mobilePhone,businessPhones,preferredLanguage";

    private static readonly string[] GraphScopes = ["https://graph.microsoft.com/User.Read"];

    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };

    private static readonly Dictionary<string, string> KnownClients = new(StringComparer.OrdinalIgnoreCase)
    {
        ["ab3be6b7-f5df-413d-ac2d-abf1e3fd9c0b"] = "Microsoft Enterprise token store (Microsoft 365 Copilot)",
        ["1fec8e78-bce4-4aaf-ab1b-5451cc387264"] = "Microsoft Teams desktop/mobile",
        ["5e3ce6c0-2b1f-4285-8d4b-75ee78787346"] = "Microsoft Teams web",
        ["aebc6443-996d-45c2-90f0-388ff96faa56"] = "Visual Studio Code",
        ["04b07795-8ddb-461a-bbee-02f9e1bf7b46"] = "Azure CLI",
    };

    [McpServerTool(Name = "get_my_profile", Title = "Get my profile", ReadOnly = true, Idempotent = true, OpenWorld = false)]
    [Description("Gets the profile of the signed-in user from Microsoft Graph (same as GET https://graph.microsoft.com/v1.0/me). " +
                 "Returns JSON with fields such as id, displayName, givenName, surname, mail, userPrincipalName, jobTitle, " +
                 "officeLocation, mobilePhone, businessPhones and preferredLanguage.")]
    public async Task<string> GetMyProfile(
        [Description("Optional comma-separated list of additional user properties to return, for example " +
                     "'department,companyName,employeeId,city,country'. Leave empty for the default /me properties.")]
        string? additionalProperties = null,
        CancellationToken cancellationToken = default)
    {
        var user = GetUser();
        var requestUri = "me";

        if (!string.IsNullOrWhiteSpace(additionalProperties))
        {
            var extra = additionalProperties.Replace(" ", string.Empty);
            if (!PropertyListRegex().IsMatch(extra))
            {
                throw new McpException("additionalProperties must be a comma-separated list of property names (letters and digits only).");
            }

            requestUri = $"me?$select={DefaultMeProperties},{extra}";
        }

        string authorizationHeader;
        try
        {
            // On-Behalf-Of flow: exchange the incoming user token for a Microsoft Graph token.
            authorizationHeader = await authorizationHeaderProvider.CreateAuthorizationHeaderForUserAsync(
                GraphScopes, claimsPrincipal: user, cancellationToken: cancellationToken);
        }
        catch (Exception ex) when (ex is MicrosoftIdentityWebChallengeUserException or MsalUiRequiredException)
        {
            logger.LogWarning(ex, "On-Behalf-Of token acquisition requires user interaction (consent or conditional access).");
            throw new McpException(
                "The server could not get a Microsoft Graph token on behalf of the user because consent or additional sign-in " +
                "is required. Ask your administrator to grant admin consent for Microsoft Graph User.Read to the webapp-mcp app.");
        }
        catch (MsalException ex)
        {
            logger.LogError(ex, "On-Behalf-Of token acquisition failed: {ErrorCode}", ex.ErrorCode);
            throw new McpException($"The server failed to acquire a Microsoft Graph token on behalf of the user ({ex.ErrorCode}).");
        }

        var client = httpClientFactory.CreateClient(GraphClientName);
        using var request = new HttpRequestMessage(HttpMethod.Get, requestUri);
        request.Headers.Authorization = AuthenticationHeaderValue.Parse(authorizationHeader);

        using var response = await client.SendAsync(request, cancellationToken);
        var body = await response.Content.ReadAsStringAsync(cancellationToken);

        if (!response.IsSuccessStatusCode)
        {
            logger.LogError("Microsoft Graph returned {StatusCode}: {Body}", (int)response.StatusCode, body);
            throw new McpException($"Microsoft Graph returned {(int)response.StatusCode} {response.ReasonPhrase}: {body}");
        }

        return body;
    }

    [McpServerTool(Name = "get_my_token_claims", Title = "Get my token claims", ReadOnly = true, Idempotent = true, OpenWorld = false)]
    [Description("Returns the identity of the signed-in user and the calling client application as seen by this MCP server " +
                 "(claims from the validated Entra ID access token). Useful for troubleshooting authentication.")]
    public string GetMyTokenClaims()
    {
        var user = GetUser();
        var clientAppId = Find(user, "azp", "appid");

        var result = new
        {
            name = Find(user, "name"),
            preferredUsername = Find(user, "preferred_username", "upn", ClaimTypes.Upn),
            objectId = Find(user, "oid", ClaimConstants.ObjectId),
            tenantId = Find(user, "tid", ClaimConstants.TenantId),
            scopes = Find(user, "scp", ClaimConstants.Scope),
            audience = Find(user, "aud"),
            issuer = Find(user, "iss"),
            tokenVersion = Find(user, "ver"),
            clientAppId,
            clientApp = clientAppId is not null && KnownClients.TryGetValue(clientAppId, out var known) ? known : null,
        };

        return JsonSerializer.Serialize(result, JsonOptions);
    }

    private ClaimsPrincipal GetUser()
    {
        var user = httpContextAccessor.HttpContext?.User;
        if (user?.Identity?.IsAuthenticated != true)
        {
            throw new McpException("No authenticated user context is available.");
        }

        return user;
    }

    private static string? Find(ClaimsPrincipal user, params string[] claimTypes)
    {
        foreach (var claimType in claimTypes)
        {
            var value = user.FindFirst(claimType)?.Value;
            if (!string.IsNullOrEmpty(value))
            {
                return value;
            }
        }

        return null;
    }

    [GeneratedRegex("^[A-Za-z0-9]+(,[A-Za-z0-9]+)*$")]
    private static partial Regex PropertyListRegex();
}
