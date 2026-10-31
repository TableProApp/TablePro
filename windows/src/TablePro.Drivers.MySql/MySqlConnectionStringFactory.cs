using MySqlConnector;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using CoreSslMode = TablePro.Core.Connections.SslMode;

namespace TablePro.Drivers.MySql;

internal static class MySqlConnectionStringFactory
{
    public static string Build(ConnectionRequest request)
    {
        var profile = request.Profile;
        var builder = new MySqlConnectionStringBuilder
        {
            Server = request.Host,
            Port = (uint)(request.Port > 0 ? request.Port : profile.EffectivePort),
            UserID = string.IsNullOrWhiteSpace(profile.Username) ? profile.Descriptor.DefaultUser : profile.Username,
            Password = request.Password ?? string.Empty,
            SslMode = MapSslMode(ConnectionTls.SslModeFor(request)),
            ConnectionTimeout = (uint)Math.Max(profile.ConnectTimeoutSeconds, 1),
            Pooling = true,
            ApplicationName = "TablePro",

            // A user script may SET @x, and a zero date such as 0000-00-00 must not fail the whole result.
            AllowUserVariables = true,
            AllowZeroDateTime = true,
            ConvertZeroDateTime = true,
        };

        if (!string.IsNullOrWhiteSpace(request.Database))
        {
            builder.Database = request.Database;
        }

        if (profile.EffectiveSignIn() == SignInMethod.Kerberos)
        {
            // MariaDB's auth_gssapi_client, answered with the Windows logon's ticket; no password is sent.
            builder.Password = string.Empty;
            if (!string.IsNullOrWhiteSpace(profile.Auth!.KerberosServiceName))
            {
                builder.ServerSPN = profile.Auth.KerberosServiceName.Trim();
            }
        }
        else if (profile.UsesSignInToken())
        {
            // The session's password provider supplies a token per physical connection. MySqlConnector sends it with
            // mysql_clear_password, which it allows only over TLS, and the TLS mode above is at least Required.
            builder.Password = string.Empty;
        }

        foreach (var (key, value) in profile.AdditionalOptions)
        {
            builder[key] = value;
        }

        return builder.ConnectionString;
    }

    public static MySqlSslMode MapSslMode(CoreSslMode mode) => mode switch
    {
        CoreSslMode.Disabled => MySqlSslMode.None,
        CoreSslMode.Required => MySqlSslMode.Required,
        CoreSslMode.VerifyCa => MySqlSslMode.VerifyCA,
        CoreSslMode.VerifyIdentity => MySqlSslMode.VerifyFull,
        _ => MySqlSslMode.Preferred,
    };
}
