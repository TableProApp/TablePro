using TablePro.Core.Drivers;

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

    /// <summary>Throws with a message naming the missing field, before any request leaves the machine.</summary>
    public void Validate(string databaseNoun)
    {
        if (AccountId.Length == 0)
        {
            throw new CloudflareApiException("Enter the Cloudflare account ID in the Host field.");
        }

        if (ApiToken.Length == 0)
        {
            throw new CloudflareApiException("Enter a Cloudflare API token in the Password field.");
        }

        if (Database.Length == 0)
        {
            throw new CloudflareApiException($"Enter the {databaseNoun} in the Database field.");
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
