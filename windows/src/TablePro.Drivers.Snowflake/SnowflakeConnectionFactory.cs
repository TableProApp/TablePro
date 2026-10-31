using System.Data.Common;
using System.Globalization;
using TablePro.Core.Drivers;
using TablePro.Core.Localization;

namespace TablePro.Drivers.Snowflake;

/// <summary>An account identifier and the host it is served from.</summary>
public readonly record struct SnowflakeAccount(string Account, string Host)
{
    private const string Domain = ".snowflakecomputing.com";
    private const string ChinaDomain = ".snowflakecomputing.cn";

    /// <summary>
    /// Accepts what users paste: a locator with region (<c>xy12345.eu-central-1</c>), an organization account
    /// (<c>myorg-myaccount</c>), a full host or a URL. The login names the account by its first segment only.
    /// </summary>
    public static SnowflakeAccount Parse(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        var value = text.Trim();
        if (value.Contains("://", StringComparison.Ordinal) && Uri.TryCreate(value, UriKind.Absolute, out var uri))
        {
            value = uri.Host;
        }

        value = value.TrimEnd('/');
        if (value.Length == 0)
        {
            throw new ArgumentException(CoreStrings.Format("Driver/NeedsAccountIdentifier", "Snowflake", "xy12345.eu-central-1, myorg-myaccount"), nameof(text));
        }

        string host;
        string identifier;
        if (value.EndsWith(Domain, StringComparison.OrdinalIgnoreCase) || value.EndsWith(ChinaDomain, StringComparison.OrdinalIgnoreCase))
        {
            host = value.ToLowerInvariant();
            identifier = value[..value.IndexOf(".snowflakecomputing.", StringComparison.OrdinalIgnoreCase)];
        }
        else
        {
            host = string.Concat(value, Domain).ToLowerInvariant();
            identifier = value;
        }

        var dot = identifier.IndexOf('.', StringComparison.Ordinal);
        return new SnowflakeAccount(dot > 0 ? identifier[..dot] : identifier, host);
    }
}

/// <summary>How a session signs in, decided from the form.</summary>
public enum SnowflakeAuthentication
{
    Password,
    KeyPair,
    ExternalBrowser,
    OAuth,
    Other,
}

/// <summary>A connection string without the password, which goes to the connection as a SecureString.</summary>
public sealed record SnowflakeConnectionSettings(string ConnectionString, string? Password, SnowflakeAuthentication Authentication)
{
    // The generated ToString would print the password into any log that formats the settings.
    public override string ToString() => ConnectionString;
}

/// <summary>
/// Builds the Snowflake.Data connection string. Form fields: Host (or AdditionalOptions <c>account</c>) is the account,
/// Username, Password, Database, FilePath as a private key file (Password then is its passphrase), and any
/// Snowflake.Data keyword in AdditionalOptions, notably <c>warehouse</c>, <c>role</c>, <c>schema</c> and
/// <c>authenticator</c> (<c>externalbrowser</c>, <c>oauth</c> with the token as Password, <c>snowflake_jwt</c>).
/// </summary>
internal static class SnowflakeConnectionFactory
{
    public const string AccountOption = "account";
    public const string SchemaOption = "schema";
    public const string AuthenticatorOption = "authenticator";

    public static SnowflakeConnectionSettings Build(ConnectionRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        var profile = request.Profile;
        var options = profile.AdditionalOptions;
        var account = SnowflakeAccount.Parse(Option(options, AccountOption) ?? profile.Host);

        var builder = new DbConnectionStringBuilder
        {
            ["account"] = account.Account,
            ["host"] = account.Host,
            ["connection_timeout"] = Math.Max(profile.ConnectTimeoutSeconds, 1).ToString(CultureInfo.InvariantCulture),
            ["application"] = "TablePro",

            // An editor tab's USE WAREHOUSE, USE ROLE or USE SCHEMA changes its pooled session; dropping such a
            // session instead of pooling it keeps the change in that tab rather than in the next sidebar read.
            ["changedsession"] = "Destroy",
        };

        // 443 is Snowflake's only public port; anything else is a proxy or private link the user typed on purpose.
        if (profile.Port is > 0 and not 443)
        {
            builder["port"] = profile.Port.ToString(CultureInfo.InvariantCulture);
        }

        if (!string.IsNullOrWhiteSpace(profile.Username))
        {
            builder["user"] = profile.Username.Trim();
        }

        if (!string.IsNullOrWhiteSpace(request.Database))
        {
            builder["db"] = request.Database.Trim();
        }

        foreach (var (key, value) in options)
        {
            if (!string.Equals(key, AccountOption, StringComparison.OrdinalIgnoreCase) && !string.IsNullOrWhiteSpace(value))
            {
                builder[key.ToLowerInvariant()] = value.Trim();
            }
        }

        var authenticator = builder.TryGetValue(AuthenticatorOption, out var named) ? Convert.ToString(named, CultureInfo.InvariantCulture)?.ToLowerInvariant() : null;
        var password = string.IsNullOrEmpty(request.Password) ? null : request.Password;
        SnowflakeAuthentication kind;
        switch (authenticator)
        {
            case "externalbrowser":
                kind = SnowflakeAuthentication.ExternalBrowser;
                password = null;
                break;
            case "oauth":
                kind = SnowflakeAuthentication.OAuth;
                if (password is not null)
                {
                    builder["token"] = password;
                }

                password = null;
                break;
            case null or "snowflake_jwt" when !string.IsNullOrWhiteSpace(profile.FilePath):
                kind = SnowflakeAuthentication.KeyPair;
                builder[AuthenticatorOption] = "snowflake_jwt";
                builder["private_key_file"] = profile.FilePath!.Trim();
                if (password is not null)
                {
                    builder["private_key_pwd"] = password;
                }

                password = null;
                break;
            case null or "snowflake":
                kind = SnowflakeAuthentication.Password;
                break;
            default:
                kind = SnowflakeAuthentication.Other;
                break;
        }

        return new SnowflakeConnectionSettings(builder.ConnectionString, password, kind);
    }

    public static string? Option(IReadOnlyDictionary<string, string> options, string key)
    {
        foreach (var (name, value) in options)
        {
            if (string.Equals(name, key, StringComparison.OrdinalIgnoreCase) && !string.IsNullOrWhiteSpace(value))
            {
                return value.Trim();
            }
        }

        return null;
    }
}
