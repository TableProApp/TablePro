using System.Globalization;
using Microsoft.Data.SqlClient;
using TablePro.Core.Drivers;
using CoreSslMode = TablePro.Core.Connections.SslMode;

namespace TablePro.Drivers.SqlServer;

internal static class SqlServerConnectionStringFactory
{
    public static string Build(ConnectionRequest request)
    {
        var profile = request.Profile;
        var port = request.Port > 0 ? request.Port : profile.EffectivePort;
        var (encrypt, trust) = MapSslMode(profile.SslMode);
        var builder = new SqlConnectionStringBuilder
        {
            DataSource = string.Create(CultureInfo.InvariantCulture, $"tcp:{request.Host},{port}"),
            Encrypt = encrypt,
            TrustServerCertificate = trust,
            ConnectTimeout = Math.Max(profile.ConnectTimeoutSeconds, 1),
            Pooling = true,
            ApplicationName = "TablePro",
        };

        if (!string.IsNullOrWhiteSpace(request.Database))
        {
            builder.InitialCatalog = request.Database;
        }

        // No user name means the Windows account, which is how most developers reach a local instance.
        if (string.IsNullOrWhiteSpace(profile.Username))
        {
            builder.IntegratedSecurity = true;
        }
        else
        {
            builder.UserID = profile.Username;
            builder.Password = request.Password ?? string.Empty;
        }

        // Routes to a readable secondary of an availability group. SQL Server has no session-wide read-only switch,
        // so on a primary this only states intent; the app's Safe Mode is what refuses writes there.
        if (profile.IsReadOnly)
        {
            builder.ApplicationIntent = ApplicationIntent.ReadOnly;
        }

        foreach (var (key, value) in profile.AdditionalOptions)
        {
            builder[key] = value;
        }

        return builder.ConnectionString;
    }

    /// <summary>
    /// Required encrypts without checking the certificate, matching what the other engines call require; the verify
    /// modes check it. Disabled and Preferred leave encryption to the server and accept its certificate if it insists.
    /// </summary>
    public static (SqlConnectionEncryptOption Encrypt, bool TrustServerCertificate) MapSslMode(CoreSslMode mode) => mode switch
    {
        CoreSslMode.Required => (SqlConnectionEncryptOption.Mandatory, true),
        CoreSslMode.VerifyCa or CoreSslMode.VerifyIdentity => (SqlConnectionEncryptOption.Mandatory, false),
        _ => (SqlConnectionEncryptOption.Optional, true),
    };
}
