using TablePro.Core.Drivers;

namespace TablePro.Core.Connections;

/// <summary>The TLS mode a driver should use for a request, once sign-in and the transport have had their say.</summary>
public static class ConnectionTls
{
    /// <summary>Whether the request dials somewhere other than the profile's host, as every tunnel makes it.</summary>
    public static bool IsTunneled(this ConnectionRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        return !string.Equals(request.Host, request.Profile.Host, StringComparison.OrdinalIgnoreCase) || request.Port != request.Profile.EffectivePort;
    }

    /// <summary>
    /// The profile's mode, raised to Required for a token sign-in, and adjusted for the transport the way the macOS
    /// app's <c>tunneledConnection</c> does:
    /// <list type="bullet">
    /// <item>The Cloud SQL Auth Proxy encrypts the hop itself and its local listener speaks plain text, so TLS is off.</item>
    /// <item>Behind any other tunnel the certificate names the server, not 127.0.0.1, so Verify identity checks the
    /// chain only. SQL Server keeps the host check by naming the server in <c>HostNameInCertificate</c>.</item>
    /// </list>
    /// </summary>
    public static SslMode SslModeFor(ConnectionRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        var profile = request.Profile;
        if (profile.ActiveTransport() == ConnectionTransport.CloudSqlProxy)
        {
            return SslMode.Disabled;
        }

        var mode = profile.EffectiveSslMode();
        return mode == SslMode.VerifyIdentity && request.IsTunneled() && profile.Engine != DatabaseEngine.SqlServer ? SslMode.VerifyCa : mode;
    }
}
