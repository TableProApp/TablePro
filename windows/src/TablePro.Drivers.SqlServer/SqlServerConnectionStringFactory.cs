using System.Globalization;
using Microsoft.Data.SqlClient;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using CoreSslMode = TablePro.Core.Connections.SslMode;

namespace TablePro.Drivers.SqlServer;

internal static class SqlServerConnectionStringFactory
{
    public static string Build(ConnectionRequest request)
    {
        var profile = request.Profile;
        var port = request.Port > 0 ? request.Port : profile.EffectivePort;
        var (encrypt, trust) = MapSslMode(ConnectionTls.SslModeFor(request));
        var builder = new SqlConnectionStringBuilder
        {
            DataSource = string.Create(CultureInfo.InvariantCulture, $"tcp:{request.Host},{port}"),
            Encrypt = encrypt,
            TrustServerCertificate = trust,
            ConnectTimeout = Math.Max(profile.ConnectTimeoutSeconds, 1),
            Pooling = true,
            ApplicationName = "TablePro",
        };

        // Behind a tunnel the driver dials 127.0.0.1, but the certificate and the Kerberos service name belong to the server.
        var tunneled = request.IsTunneled();
        if (tunneled && !trust)
        {
            builder.HostNameInCertificate = profile.Host;
        }

        if (!string.IsNullOrWhiteSpace(request.Database))
        {
            builder.InitialCatalog = request.Database;
        }

        switch (profile.EffectiveSignIn())
        {
            case SignInMethod.WindowsIntegrated:
                builder.IntegratedSecurity = true;
                if (tunneled)
                {
                    builder.ServerSPN = string.Create(CultureInfo.InvariantCulture, $"MSSQLSvc/{profile.Host}:{profile.EffectivePort}");
                }

                break;

            case SignInMethod.EntraId:
                ApplyEntra(builder, profile, request.Password);
                break;

            // No user name means the Windows account, which is how most developers reach a local instance.
            case var _ when string.IsNullOrWhiteSpace(profile.Username):
                builder.IntegratedSecurity = true;
                break;

            default:
                builder.UserID = profile.Username;
                builder.Password = request.Password ?? string.Empty;
                break;
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

    public static SqlAuthenticationMethod MapEntraMode(EntraAuthMode mode) => mode switch
    {
        EntraAuthMode.DeviceCode => SqlAuthenticationMethod.ActiveDirectoryDeviceCodeFlow,
        EntraAuthMode.Default => SqlAuthenticationMethod.ActiveDirectoryDefault,
        EntraAuthMode.ManagedIdentity => SqlAuthenticationMethod.ActiveDirectoryManagedIdentity,
        EntraAuthMode.ServicePrincipal => SqlAuthenticationMethod.ActiveDirectoryServicePrincipal,
        EntraAuthMode.Integrated => SqlAuthenticationMethod.ActiveDirectoryIntegrated,
        _ => SqlAuthenticationMethod.ActiveDirectoryInteractive,
    };

    /// <summary>
    /// SqlClient signs in itself through the <c>Authentication</c> keyword. The User ID carries what each mode takes:
    /// the login hint for a browser sign-in, the client id of a service principal or a user-assigned identity.
    /// </summary>
    private static void ApplyEntra(SqlConnectionStringBuilder builder, ConnectionProfile profile, string? secret)
    {
        var auth = profile.Auth!;
        SqlServerEntraSignIn.EnsureRegistered();
        builder.Authentication = MapEntraMode(auth.EntraMode);

        // Azure SQL refuses an Entra sign-in on an unencrypted connection.
        if (builder.Encrypt == SqlConnectionEncryptOption.Optional)
        {
            builder.Encrypt = SqlConnectionEncryptOption.Mandatory;
        }

        var clientId = string.IsNullOrWhiteSpace(auth.EntraClientId) ? null : auth.EntraClientId.Trim();
        switch (auth.EntraMode)
        {
            case EntraAuthMode.Interactive when !string.IsNullOrWhiteSpace(profile.Username):
                builder.UserID = profile.Username.Trim();
                break;
            case EntraAuthMode.ServicePrincipal:
                builder.UserID = clientId ?? string.Empty;
                builder.Password = secret ?? string.Empty;
                break;
            case EntraAuthMode.ManagedIdentity or EntraAuthMode.Default when clientId is not null:
                builder.UserID = clientId;
                break;
        }
    }
}
