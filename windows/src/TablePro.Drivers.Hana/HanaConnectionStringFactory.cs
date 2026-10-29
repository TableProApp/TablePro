using System.Globalization;
using TablePro.Core.Drivers;
using TablePro.Drivers.Hana.Localization;
using TablePro.Drivers.Odbc;
using CoreSslMode = TablePro.Core.Connections.SslMode;

namespace TablePro.Drivers.Hana;

/// <summary>
/// Builds the connection string for SAP's HDBODBC driver. The Database field is the schema the session opens on, as
/// on macOS; a tenant reached through the system database's port comes from the <c>tenant</c> option as
/// <c>DATABASENAME</c>.
/// </summary>
/// <remarks>
/// HANA has no opportunistic TLS, and the macOS driver encrypts for every mode but Disabled, so the modes map as:
/// Disabled sends <c>ENCRYPT=FALSE</c>. Preferred and Required encrypt without checking the certificate. Verify CA checks
/// the chain and skips the host name with <c>sslHostNameInCertificate=*</c>, the wildcard SAP documents for that.
/// Verify Identity checks both, against the name in the <c>hanaTLSServerName</c> option or the profile's host, which
/// stays right when an SSH tunnel dials 127.0.0.1. The trust store is the HANA client's default (the Windows store
/// with its mscrypto provider) unless <c>sslTrustStore</c> or <c>sslCryptoProvider</c> is passed as an option.
/// </remarks>
internal static class HanaConnectionStringFactory
{
    public const string DefaultDriver = "HDBODBC";
    public const string TlsServerNameOption = "hanaTLSServerName";
    public const string TenantOption = "tenant";
    public const string ReadOnlyMarker = "sessionVariable:TABLEPRO_ACCESS";

    // Built per session rather than once, so the install hint is in the language of the session that may need it.
    public static OdbcDriverInfo Driver => new("SAP HANA", DefaultDriver, HanaStrings.Get("Hana/InstallHint"));

    private static readonly string[] ConsumedOptions = [OdbcConnectionString.DriverOption, TlsServerNameOption, TenantOption];

    private static readonly string[] ManagedKeys =
        ["DRIVER", "DSN", "FILEDSN", "SERVERNODE", "UID", "PWD", "ENCRYPT", "sslValidateCertificate", "sslHostNameInCertificate", "CURRENTSCHEMA"];

    public static string Build(ConnectionRequest request) => Create(request).ToString();

    public static OdbcConnectionString Create(ConnectionRequest request)
    {
        var profile = request.Profile;
        var options = profile.AdditionalOptions;
        var port = request.Port > 0 ? request.Port : profile.EffectivePort;
        var connection = new OdbcConnectionString()
            .Set("DRIVER", OdbcConnectionString.Option(options, OdbcConnectionString.DriverOption) ?? DefaultDriver)
            .Set("SERVERNODE", ServerNode(request.Host, port));

        if (!string.IsNullOrWhiteSpace(profile.Username))
        {
            connection.Set("UID", profile.Username).Set("PWD", request.Password ?? string.Empty);
        }

        if (OdbcConnectionString.Option(options, TenantOption) is { } tenant)
        {
            connection.Set("DATABASENAME", tenant);
        }

        ApplySsl(connection, profile.SslMode, OdbcConnectionString.Option(options, TlsServerNameOption) ?? profile.Host);

        // The ODBC driver manager pools by connection string and keeps a pooled session's state, so a read-only
        // profile's connections are kept apart from a writable profile's to the same login. A session variable is a
        // documented client property that changes nothing else.
        if (profile.IsReadOnly)
        {
            connection.Set(ReadOnlyMarker, "READONLY");
        }

        // The client's own connect timeout, in milliseconds, bounds the TCP and TLS handshake the ODBC login timeout
        // may not reach.
        connection.Set("CONNECTTIMEOUT", (Math.Max(profile.ConnectTimeoutSeconds, 1) * 1000L).ToString(CultureInfo.InvariantCulture));
        connection.AddPassThrough(options, ConsumedOptions, ManagedKeys);
        return connection;
    }

    /// <summary>host:port, with an IPv6 address in brackets so its colons are not read as the port's.</summary>
    public static string ServerNode(string host, int port)
    {
        var name = host.Trim();
        if (name.Contains(':', StringComparison.Ordinal) && !name.StartsWith('['))
        {
            name = string.Concat("[", name, "]");
        }

        return string.Create(CultureInfo.InvariantCulture, $"{name}:{port}");
    }

    private static void ApplySsl(OdbcConnectionString connection, CoreSslMode mode, string tlsName)
    {
        if (mode == CoreSslMode.Disabled)
        {
            connection.Set("ENCRYPT", "FALSE");
            return;
        }

        connection.Set("ENCRYPT", "TRUE");
        switch (mode)
        {
            case CoreSslMode.Preferred or CoreSslMode.Required:
                connection.Set("sslValidateCertificate", "FALSE");
                break;
            case CoreSslMode.VerifyCa:
                connection.Set("sslValidateCertificate", "TRUE").Set("sslHostNameInCertificate", "*");
                break;
            default:
                connection.Set("sslValidateCertificate", "TRUE").Set("sslHostNameInCertificate", tlsName.Trim());
                break;
        }
    }
}
