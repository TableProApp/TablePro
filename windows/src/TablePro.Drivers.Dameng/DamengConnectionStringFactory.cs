using System.Globalization;
using TablePro.Core.Drivers;
using TablePro.Drivers.Odbc;
using CoreSslMode = TablePro.Core.Connections.SslMode;

namespace TablePro.Drivers.Dameng;

/// <summary>
/// Builds the connection string for Dameng's ODBC driver: <c>SERVER</c>, <c>TCP_PORT</c>, <c>UID</c> and <c>PWD</c>.
/// The Database field is the schema the session opens on, as on macOS, and is applied with <c>SET SCHEMA</c>.
/// </summary>
/// <remarks>
/// DM8's TLS is certificate based: the client presents the certificates in the directory <c>SSL_PATH</c> names
/// (unlocked by <c>SSL_PWD</c>) and checks the server's against the CA there. There is no opportunistic TLS and no
/// host-name check, so the modes map as follows. Disabled never sends the SSL keys. Preferred uses TLS only when
/// <c>SSL_PATH</c> is set. Required and Verify CA need <c>SSL_PATH</c> and fail without it. Verify Identity is refused,
/// since nothing in the driver would match the certificate to the host.
/// </remarks>
internal static class DamengConnectionStringFactory
{
    public const string DefaultDriver = "DM8 ODBC DRIVER";
    public const string SslPathOption = "SSL_PATH";
    public const string SslPasswordOption = "SSL_PWD";

    public static readonly OdbcDriverInfo Driver = new(
        "Dameng",
        DefaultDriver,
        "Install the 64-bit DM8 client from Dameng (eco.dameng.com), which registers the ODBC driver, or name another installed driver with the odbcDriver option.");

    private static readonly string[] ConsumedOptions = [OdbcConnectionString.DriverOption, SslPathOption, SslPasswordOption];

    private static readonly string[] ManagedKeys = ["DRIVER", "DSN", "FILEDSN", "SERVER", "TCP_PORT", "UID", "PWD"];

    public static string Build(ConnectionRequest request) => Create(request).ToString();

    public static OdbcConnectionString Create(ConnectionRequest request)
    {
        var profile = request.Profile;
        var port = request.Port > 0 ? request.Port : profile.EffectivePort;
        var options = profile.AdditionalOptions;
        var connection = new OdbcConnectionString()
            .Set("DRIVER", OdbcConnectionString.Option(options, OdbcConnectionString.DriverOption) ?? DefaultDriver)
            .Set("SERVER", request.Host)
            .Set("TCP_PORT", port.ToString(CultureInfo.InvariantCulture));

        if (!string.IsNullOrWhiteSpace(profile.Username))
        {
            connection.Set("UID", profile.Username).Set("PWD", request.Password ?? string.Empty);
        }

        ApplySsl(connection, profile.SslMode, options);
        connection.AddPassThrough(options, ConsumedOptions, ManagedKeys);
        return connection;
    }

    private static void ApplySsl(OdbcConnectionString connection, CoreSslMode mode, IReadOnlyDictionary<string, string> options)
    {
        var path = OdbcConnectionString.Option(options, SslPathOption);
        switch (mode)
        {
            case CoreSslMode.Disabled:
                return;
            case CoreSslMode.Preferred when path is null:
                return;
            case CoreSslMode.VerifyIdentity:
                throw new ArgumentException(
                    "Dameng's TLS checks the server certificate against the CA in SSL_PATH but never matches it to the host name. Choose Verify CA, or use an SSH tunnel.");
            case CoreSslMode.Required or CoreSslMode.VerifyCa when path is null:
                throw new ArgumentException(
                    "Dameng encrypts with client certificates: set the SSL_PATH option to the directory holding them (and SSL_PWD if they are protected).");
        }

        connection.Set(SslPathOption, path!);
        if (OdbcConnectionString.Option(options, SslPasswordOption) is { } password)
        {
            connection.Set(SslPasswordOption, password);
        }
    }
}
