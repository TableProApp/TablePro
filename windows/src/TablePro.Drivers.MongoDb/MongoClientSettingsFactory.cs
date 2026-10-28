using System.Globalization;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
using MongoDB.Driver;
using MongoDB.Driver.Core.Configuration;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;

namespace TablePro.Drivers.MongoDb;

/// <summary>
/// Builds the driver's client settings from a connection. Options the form has no field for come from
/// <see cref="ConnectionProfile.AdditionalOptions"/>: <c>srv</c>, <c>authSource</c>, <c>authMechanism</c> and
/// <c>replicaSet</c>.
/// </summary>
internal static class MongoClientSettingsFactory
{
    public const string SrvOption = "srv";
    public const string AuthSourceOption = "authSource";
    public const string AuthMechanismOption = "authMechanism";
    public const string ReplicaSetOption = "replicaSet";
    public const string ApplicationName = "TablePro";

    public static MongoClientSettings Build(ConnectionRequest request)
    {
        var profile = request.Profile;
        var useSrv = IsOn(profile, SrvOption);
        var tunneled = profile.Ssh?.Enabled == true || !string.Equals(request.Host, profile.Host, StringComparison.OrdinalIgnoreCase);
        if (useSrv && tunneled)
        {
            throw new InvalidOperationException("A DNS seed list (mongodb+srv) cannot run through an SSH tunnel: the tunnel carries one host, and the seed list names the servers by DNS. Turn off the seed list and connect to one member's host and port.");
        }

        var timeout = TimeSpan.FromSeconds(Math.Max(1, profile.ConnectTimeoutSeconds));
        var settings = new MongoClientSettings
        {
            ApplicationName = ApplicationName,
            ConnectTimeout = timeout,
            ServerSelectionTimeout = timeout,

            // A save counts the documents each write reached, and a retried write could reach them twice.
            RetryWrites = false,
        };

        var replicaSet = Option(profile, ReplicaSetOption);
        if (useSrv)
        {
            settings.Scheme = ConnectionStringScheme.MongoDBPlusSrv;
            settings.Server = new MongoServerAddress(request.Host);
        }
        else
        {
            var servers = Servers(request.Host, request.Port);
            settings.Servers = servers;

            // One host is used as named, as mongosh does: a replica set member is never swapped for the names the set
            // gives its members, which a tunnel or a NAT may not reach.
            settings.DirectConnection = servers.Count == 1 && replicaSet is null;
        }

        if (replicaSet is not null)
        {
            settings.ReplicaSetName = replicaSet;
        }

        if (!string.IsNullOrEmpty(profile.Username))
        {
            var source = AuthSource(profile, useSrv);
            var mechanism = Option(profile, AuthMechanismOption);
            settings.Credential = mechanism is null
                ? MongoCredential.CreateCredential(source, profile.Username, request.Password ?? string.Empty)
                : new MongoCredential(mechanism, new MongoInternalIdentity(source, profile.Username), new PasswordEvidence(request.Password ?? string.Empty));
        }

        ApplyTls(settings, profile, useSrv, tunneled);
        return settings;
    }

    /// <summary>
    /// The database a login is checked in: the one named, else <c>admin</c> for a seed list, else the connection's
    /// database, else <c>admin</c>, as mongosh and the macOS app choose.
    /// </summary>
    public static string AuthSource(ConnectionProfile profile, bool useSrv)
    {
        if (Option(profile, AuthSourceOption) is { } explicitSource)
        {
            return explicitSource;
        }

        if (Option(profile, AuthMechanismOption) is { } mechanism && mechanism.ToUpperInvariant() is "MONGODB-X509" or "MONGODB-AWS")
        {
            return "$external";
        }

        return useSrv || string.IsNullOrWhiteSpace(profile.Database) ? "admin" : profile.Database;
    }

    /// <summary>The hosts to dial. A profile may list several, comma separated, to seed a replica set.</summary>
    public static IReadOnlyList<MongoServerAddress> Servers(string host, int port)
    {
        var parts = host.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length <= 1)
        {
            return [new MongoServerAddress(parts.Length == 0 ? "localhost" : Bracketed(parts[0]), port)];
        }

        var servers = new List<MongoServerAddress>(parts.Length);
        foreach (var part in parts)
        {
            var colon = part.LastIndexOf(':');
            var closing = part.LastIndexOf(']');

            // A port follows the last colon only after a bracketed IPv6 address or a name with one colon.
            var hasPort = colon > closing && (closing >= 0 || part.IndexOf(':') == colon)
                && int.TryParse(part.AsSpan(colon + 1), NumberStyles.None, CultureInfo.InvariantCulture, out _);
            servers.Add(hasPort
                ? new MongoServerAddress(Bracketed(part[..colon]), int.Parse(part.AsSpan(colon + 1), NumberStyles.None, CultureInfo.InvariantCulture))
                : new MongoServerAddress(Bracketed(part), port));
        }

        return servers;
    }
    public static bool IsOn(ConnectionProfile profile, string option) =>
        Option(profile, option) is { } value && (value.Equals("true", StringComparison.OrdinalIgnoreCase) || value == "1" || value.Equals("yes", StringComparison.OrdinalIgnoreCase));

    public static string? Option(ConnectionProfile profile, string name)
    {
        foreach (var (key, value) in profile.AdditionalOptions)
        {
            if (string.Equals(key, name, StringComparison.OrdinalIgnoreCase) && !string.IsNullOrWhiteSpace(value))
            {
                return value.Trim();
            }
        }

        return null;
    }

    // The driver takes an IPv6 address in brackets, as a connection string writes it.
    private static string Bracketed(string host) => host.Contains(':', StringComparison.Ordinal) && !host.StartsWith('[') ? $"[{host}]" : host;

    /// <summary>
    /// MongoDB cannot fall back from TLS to plain text, so Preferred means plain text on a host and TLS on a seed list,
    /// which is what a mongodb+srv string turns on by default.
    /// </summary>
    private static void ApplyTls(MongoClientSettings settings, ConnectionProfile profile, bool useSrv, bool tunneled)
    {
        var mode = profile.SslMode;
        var enabled = mode switch
        {
            SslMode.Disabled => false,
            SslMode.Preferred => useSrv,
            _ => true,
        };
        settings.UseTls = enabled;
        if (!enabled)
        {
            return;
        }

        var expectedHost = profile.Host;
        switch (mode)
        {
            case SslMode.Preferred or SslMode.Required:
                settings.AllowInsecureTls = true;
                break;
            case SslMode.VerifyCa:
                settings.SslSettings = new SslSettings { ServerCertificateValidationCallback = (_, _, _, errors) => (errors & ~SslPolicyErrors.RemoteCertificateNameMismatch) == SslPolicyErrors.None };
                break;
            case SslMode.VerifyIdentity when tunneled:
                // Through a tunnel the driver dials 127.0.0.1, so the certificate is checked against the host the user typed.
                settings.SslSettings = new SslSettings
                {
                    ServerCertificateValidationCallback = (_, certificate, _, errors) =>
                        (errors & ~SslPolicyErrors.RemoteCertificateNameMismatch) == SslPolicyErrors.None && MatchesHost(certificate, expectedHost),
                };
                break;
        }
    }

    private static bool MatchesHost(X509Certificate? certificate, string host)
    {
        if (certificate is null)
        {
            return false;
        }

        using var loaded = X509CertificateLoader.LoadCertificate(certificate.GetRawCertData());
        return loaded.MatchesHostname(host);
    }
}
