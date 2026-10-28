using Npgsql;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using CoreGssEncryptionMode = TablePro.Core.Connections.GssEncryptionMode;
using CoreSslMode = TablePro.Core.Connections.SslMode;

namespace TablePro.Drivers.PostgreSql;

internal static class PostgreSqlConnectionStringFactory
{
    // A session-level default: every transaction the connection starts is read-only, including the implicit ones.
    private const string ReadOnlyOption = "-c default_transaction_read_only=on";

    public static string Build(ConnectionRequest request)
    {
        var profile = request.Profile;
        var builder = new NpgsqlConnectionStringBuilder
        {
            Host = request.Host,
            Port = request.Port > 0 ? request.Port : profile.EffectivePort,
            Database = string.IsNullOrWhiteSpace(request.Database) ? "postgres" : request.Database,
            Username = string.IsNullOrWhiteSpace(profile.Username) ? profile.Descriptor.DefaultUser : profile.Username,
            Password = request.Password,
            SslMode = MapSslMode(ConnectionTls.SslModeFor(request)),
            Timeout = Math.Max(profile.ConnectTimeoutSeconds, 1),
            Pooling = true,
            ApplicationName = "TablePro",
        };

        if (profile.EffectiveSignIn() == SignInMethod.Kerberos)
        {
            // Npgsql answers the server's GSSAPI request with the Windows logon's ticket through SSPI. Without a user
            // name it signs in as the Windows account, the usual principal-to-role mapping.
            var auth = profile.Auth!;
            builder.Password = null;
            builder.Username = string.IsNullOrWhiteSpace(profile.Username) ? null : profile.Username;
            builder.GssEncryptionMode = MapGssEncryption(auth.GssEncryption);
            if (!string.IsNullOrWhiteSpace(auth.KerberosServiceName))
            {
                builder.KerberosServiceName = auth.KerberosServiceName.Trim();
            }
        }
        else if (profile.UsesSignInToken())
        {
            // The session's password provider mints a token for each new physical connection.
            builder.Password = null;
        }

        foreach (var (key, value) in profile.AdditionalOptions)
        {
            builder[key] = value;
        }

        // Added after the user's options so an Options keyword of their own cannot drop it.
        if (profile.IsReadOnly)
        {
            builder.Options = string.IsNullOrWhiteSpace(builder.Options) ? ReadOnlyOption : string.Concat(builder.Options, " ", ReadOnlyOption);
        }

        return builder.ConnectionString;
    }

    public static Npgsql.SslMode MapSslMode(CoreSslMode mode) => mode switch
    {
        CoreSslMode.Disabled => Npgsql.SslMode.Disable,
        CoreSslMode.Required => Npgsql.SslMode.Require,
        CoreSslMode.VerifyCa => Npgsql.SslMode.VerifyCA,
        CoreSslMode.VerifyIdentity => Npgsql.SslMode.VerifyFull,
        _ => Npgsql.SslMode.Prefer,
    };

    public static Npgsql.GssEncryptionMode MapGssEncryption(CoreGssEncryptionMode mode) => mode switch
    {
        CoreGssEncryptionMode.Disable => Npgsql.GssEncryptionMode.Disable,
        CoreGssEncryptionMode.Require => Npgsql.GssEncryptionMode.Require,
        _ => Npgsql.GssEncryptionMode.Prefer,
    };
}
