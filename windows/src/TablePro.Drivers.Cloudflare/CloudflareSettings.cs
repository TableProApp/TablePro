using TablePro.Core.Drivers;
using TablePro.Drivers.Cloudflare.Localization;

namespace TablePro.Drivers.Cloudflare;

/// <summary>
/// Where a Cloudflare connection points. The form has no Cloudflare fields of its own, so the account ID rides in Host,
/// the API token in Password and the D1 database or R2 bucket in Database. The macOS field ids are read too, so a
/// profile imported from the Mac keeps working.
/// </summary>
internal sealed record CloudflareSettings(string AccountId, string ApiToken, string Database)
{
    private static readonly string[] AccountKeys = ["accountId", "cfAccountId", "r2AccountId"];
    private static readonly string[] DatabaseKeys = ["database", "r2Bucket", "bucket"];

    public static CloudflareSettings From(ConnectionRequest request)
    {
        var profile = request.Profile;
        var account = Option(profile.AdditionalOptions, AccountKeys) ?? AccountFromHost(profile.Host);
        var database = request.Database ?? profile.Database;
        if (string.IsNullOrWhiteSpace(database))
        {
            database = Option(profile.AdditionalOptions, DatabaseKeys);
        }

        return new CloudflareSettings(account?.Trim() ?? string.Empty, request.Password?.Trim() ?? string.Empty, database?.Trim() ?? string.Empty);
    }

    /// <summary>
    /// Throws with a message naming the missing field, before any request leaves the machine.
    /// <paramref name="missingDatabase"/> is the whole sentence for an empty Database field, since what goes there differs
    /// by service and a noun spliced into a shared sentence cannot be translated.
    /// </summary>
    public void Validate(string missingDatabase)
    {
        if (AccountId.Length == 0)
        {
            throw new CloudflareApiException(CloudflareStrings.Get("Cloudflare/EnterAccountId"));
        }

        if (ApiToken.Length == 0)
        {
            throw new CloudflareApiException(CloudflareStrings.Get("Cloudflare/EnterApiToken"));
        }

        if (Database.Length == 0)
        {
            throw new CloudflareApiException(missingDatabase);
        }
    }

    // The profile's Host defaults to localhost, which is never an account ID.
    private static string? AccountFromHost(string? host) =>
        string.IsNullOrWhiteSpace(host) || host.Equals("localhost", StringComparison.OrdinalIgnoreCase) || host == "127.0.0.1" ? null : host;

    private static string? Option(IReadOnlyDictionary<string, string> options, string[] keys)
    {
        foreach (var key in keys)
        {
            if (options.TryGetValue(key, out var value) && !string.IsNullOrWhiteSpace(value))
            {
                return value;
            }
        }

        return null;
    }
}
