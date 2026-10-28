using System.Globalization;
using System.Text;
using Oracle.ManagedDataAccess.Client;
using TablePro.Core.Drivers;
using CoreSslMode = TablePro.Core.Connections.SslMode;

namespace TablePro.Drivers.Oracle;

/// <summary>
/// Builds an ODP.NET managed (thin) connection string. The Database field is the service name; a SID comes from the
/// <c>sid</c> option. The data source is always a full connect descriptor, so TCPS and the certificate check are
/// spelled out rather than left to a tnsnames.ora the machine may not have.
/// </summary>
internal static class OracleConnectionStringFactory
{
    public const string SidOption = "sid";
    public const string PrivilegeOption = "dbaPrivilege";
    public const string WalletOption = "walletLocation";

    private static readonly string[] ConsumedOptions = [SidOption, PrivilegeOption, WalletOption];

    public static string Build(ConnectionRequest request)
    {
        var profile = request.Profile;
        var builder = new OracleConnectionStringBuilder
        {
            DataSource = Descriptor(request),
            ConnectionTimeout = Math.Max(profile.ConnectTimeoutSeconds, 1),
            Pooling = true,
        };

        if (!string.IsNullOrWhiteSpace(profile.Username))
        {
            builder.UserID = profile.Username;
            builder.Password = request.Password ?? string.Empty;
        }

        if (Option(request, PrivilegeOption) is { } privilege)
        {
            builder.DBAPrivilege = privilege.ToUpperInvariant();
        }

        if (Option(request, WalletOption) is { } wallet)
        {
            builder.WalletLocation = wallet;
        }

        foreach (var (key, value) in profile.AdditionalOptions)
        {
            if (!ConsumedOptions.Contains(key, StringComparer.OrdinalIgnoreCase))
            {
                builder[key] = value;
            }
        }

        return builder.ConnectionString;
    }

    /// <summary>
    /// Oracle has no opportunistic TLS, so Disabled and Preferred dial TCP. Required and VerifyCa dial TCPS without
    /// matching the certificate's name; VerifyIdentity matches it.
    /// </summary>
    public static string Descriptor(ConnectionRequest request)
    {
        var profile = request.Profile;
        var port = request.Port > 0 ? request.Port : profile.EffectivePort;
        var tls = profile.SslMode is CoreSslMode.Required or CoreSslMode.VerifyCa or CoreSslMode.VerifyIdentity;
        var sid = Option(request, SidOption);
        var service = string.IsNullOrWhiteSpace(request.Database) ? null : request.Database.Trim();

        var sql = new StringBuilder("(DESCRIPTION=");
        sql.Append(CultureInfo.InvariantCulture, $"(CONNECT_TIMEOUT={Math.Max(profile.ConnectTimeoutSeconds, 1)})");
        sql.Append("(ADDRESS=(PROTOCOL=").Append(tls ? "TCPS" : "TCP").Append(")(HOST=").Append(Checked(request.Host, "host"))
            .Append(CultureInfo.InvariantCulture, $")(PORT={port}))");
        sql.Append("(CONNECT_DATA=");
        if (sid is not null)
        {
            sql.Append("(SID=").Append(Checked(sid, "SID")).Append(')');
        }
        else if (service is not null)
        {
            sql.Append("(SERVICE_NAME=").Append(Checked(service, "service name")).Append(')');
        }

        sql.Append(')');
        if (tls)
        {
            sql.Append("(SECURITY=(SSL_SERVER_DN_MATCH=").Append(profile.SslMode == CoreSslMode.VerifyIdentity ? "TRUE" : "FALSE").Append("))");
        }

        return sql.Append(')').ToString();
    }

    /// <summary>The schema the session opens on: the login, folded to upper case as Oracle folds unquoted names.</summary>
    public static string? DefaultSchema(string? username)
    {
        if (string.IsNullOrWhiteSpace(username))
        {
            return null;
        }

        var name = username.Trim();

        // "SYS AS SYSDBA" style logins name the user first.
        var space = name.IndexOf(' ', StringComparison.Ordinal);
        if (space > 0 && name[0] != '"')
        {
            name = name[..space];
        }

        return name.Length > 1 && name[0] == '"' && name[^1] == '"' ? name[1..^1] : name.ToUpperInvariant();
    }

    private static string? Option(ConnectionRequest request, string key)
    {
        foreach (var (name, value) in request.Profile.AdditionalOptions)
        {
            if (string.Equals(name, key, StringComparison.OrdinalIgnoreCase) && !string.IsNullOrWhiteSpace(value))
            {
                return value.Trim();
            }
        }

        return null;
    }

    // A parenthesis or equals sign would end the descriptor's value early and let the text add its own clauses.
    private static string Checked(string value, string what) =>
        value.AsSpan().IndexOfAny("()=") >= 0
            ? throw new ArgumentException($"The {what} \"{value}\" holds a character Oracle connect descriptors do not allow.")
            : value;
}
