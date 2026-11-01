using Teradata.Client.Provider;
using TablePro.Core.Drivers;
using CoreSslMode = TablePro.Core.Connections.SslMode;

namespace TablePro.Drivers.Teradata;

/// <summary>
/// Builds a Teradata .NET provider connection string. The Database field is the default database the session works
/// in; the logon mechanism and the CA file come from the <c>logmech</c> and <c>sslca</c> options.
/// </summary>
internal static class TeradataConnectionStringFactory
{
    public const string LogonMechanismOption = "logmech";
    public const string CertificateAuthorityOption = "sslca";

    private static readonly string[] ConsumedOptions = [LogonMechanismOption, CertificateAuthorityOption];

    public static string Build(ConnectionRequest request)
    {
        var profile = request.Profile;
        var builder = new TdConnectionStringBuilder
        {
            DataSource = request.Host,
            PortNumber = request.Port > 0 ? request.Port : profile.EffectivePort,
            ConnectionTimeout = Math.Max(profile.ConnectTimeoutSeconds, 1),
            ConnectionPooling = true,
            SslMode = MapSslMode(profile.SslMode),
        };

        if (!string.IsNullOrWhiteSpace(profile.Username))
        {
            builder.UserId = profile.Username;
            builder.Password = request.Password ?? string.Empty;
        }

        if (!string.IsNullOrWhiteSpace(request.Database))
        {
            builder.Database = request.Database;
        }

        foreach (var (key, value) in profile.AdditionalOptions)
        {
            if (string.Equals(key, LogonMechanismOption, StringComparison.OrdinalIgnoreCase))
            {
                builder.AuthenticationMechanism = value.Trim().ToUpperInvariant();
            }
            else if (string.Equals(key, CertificateAuthorityOption, StringComparison.OrdinalIgnoreCase))
            {
                builder.SslCA = value;
            }
            else if (!ConsumedOptions.Contains(key, StringComparer.OrdinalIgnoreCase))
            {
                builder[key] = value;
            }
        }

        return builder.ConnectionString;
    }

    /// <summary>
    /// The provider's own mode names. Preferred tries TLS and falls back to a plain logon, which only Teradata among
    /// the three engines here can do; Required encrypts without checking the certificate.
    /// </summary>
    public static string MapSslMode(CoreSslMode mode) => mode switch
    {
        CoreSslMode.Disabled => "Disable",
        CoreSslMode.Required => "Require",
        CoreSslMode.VerifyCa => "Verify-CA",
        CoreSslMode.VerifyIdentity => "Verify-Full",
        _ => "Prefer",
    };
}
