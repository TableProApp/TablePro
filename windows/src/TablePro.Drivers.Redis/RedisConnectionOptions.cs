using System.Globalization;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
using StackExchange.Redis;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;

namespace TablePro.Drivers.Redis;

/// <summary>
/// What to dial for one connection. <see cref="Sentinel"/> is set in Sentinel mode only: those options reach the
/// Sentinels, which name the primary that <see cref="Data"/> then connects to. <see cref="Mode"/> is what is dialed,
/// which a tunnel makes standalone whatever <see cref="RequestedMode"/> the profile chose.
/// </summary>
internal sealed record RedisConnectPlan(
    RedisConnectionMode Mode,
    RedisConnectionMode RequestedMode,
    ConfigurationOptions Data,
    ConfigurationOptions? Sentinel,
    bool Tunneled);

/// <summary>Turns a connection request into the client library's options, and names databases as the sidebar does.</summary>
internal static class RedisConnectionOptions
{
    public const string ClientName = "TablePro";

    /// <summary>The options the data connection uses; see <see cref="Plan"/> for the mode as a whole.</summary>
    public static ConfigurationOptions Build(ConnectionRequest request) => Plan(request).Data;

    /// <summary>
    /// Form fields win over <see cref="ConnectionProfile.AdditionalOptions"/>, which carry the connection mode, the
    /// node lists, certificate paths and whatever the form has no field for (<c>syncTimeout</c>, <c>protocol</c>,
    /// <c>sslHost</c> and the like).
    /// </summary>
    public static RedisConnectPlan Plan(ConnectionRequest request)
    {
        var profile = request.Profile;
        var settings = profile.AdditionalOptions;
        var requested = RedisTopologyKeys.ResolveMode(settings);
        var tunneled = request.IsTunneled();

        var options = LibraryOptions(settings);
        options.EndPoints.Clear();
        options.Password = string.IsNullOrEmpty(request.Password) ? null : request.Password;
        options.User = string.IsNullOrWhiteSpace(profile.Username) ? null : profile.Username.Trim();
        options.ConnectTimeout = (int)Math.Clamp(profile.ConnectTimeoutSeconds * 1000L, 1000, int.MaxValue);
        options.AbortOnConnectFail = true;

        // The editor runs CONFIG, CLIENT, INFO and FLUSHDB, which the library refuses without admin mode. Safe Mode
        // and the read-only guard decide what may run, not the library.
        options.AllowAdmin = true;
        options.ClientName ??= ClientName;

        var databaseText = string.IsNullOrWhiteSpace(request.Database) ? RedisTopologyKeys.Read(settings, ["redisDatabase"]) : request.Database;
        var database = ParseDatabaseIndex(databaseText);
        var port = request.Port > 0 ? request.Port : profile.EffectivePort;

        // A tunnel forwards one address, so whatever the mode, the connection is to the one node at its end.
        var mode = tunneled ? RedisConnectionMode.Standalone : requested;
        ConfigurationOptions? sentinel = null;
        switch (mode)
        {
            case RedisConnectionMode.Cluster:
                if (database != 0)
                {
                    throw new ArgumentException("Redis Cluster serves database 0 only. Clear the database number, or use standalone mode.");
                }

                foreach (var node in Nodes(settings, RedisTopologyKeys.ClusterHosts, RedisTopologyKeys.ClusterDefaultPort, request.Host, port))
                {
                    options.EndPoints.Add(node.Host, node.Port);
                }

                options.DefaultDatabase = 0;
                break;
            case RedisConnectionMode.Sentinel:
                var group = RedisTopologyKeys.Read(settings, RedisTopologyKeys.PrimaryGroup) ?? RedisTopologyKeys.DefaultPrimaryGroup;
                options.ServiceName = group;
                options.DefaultDatabase = database;
                sentinel = SentinelOptions(settings, group, options.ConnectTimeout);
                foreach (var node in Nodes(settings, RedisTopologyKeys.SentinelHosts, RedisTopologyKeys.SentinelDefaultPort, request.Host, port))
                {
                    sentinel.EndPoints.Add(node.Host, node.Port);
                }

                break;
            default:
                options.EndPoints.Add(request.Host, port);
                options.DefaultDatabase = database;
                break;
        }

        var tls = profile.SslMode;
        ApplyTls(options, settings, tls, mode == RedisConnectionMode.Standalone ? profile.Host : null);
        if (sentinel is not null)
        {
            ApplyTls(sentinel, settings, tls, null);
        }

        return new RedisConnectPlan(mode, requested, options, sentinel, tunneled);
    }

    /// <summary>Redis has no in-band TLS upgrade, so Preferred cannot fall back and stays plain like Disabled.</summary>
    public static bool UsesTls(SslMode mode) => mode is SslMode.Required or SslMode.VerifyCa or SslMode.VerifyIdentity;

    public static bool AcceptsCertificate(SslMode mode, SslPolicyErrors errors) => mode switch
    {
        SslMode.Required => true,
        SslMode.VerifyCa => (errors & ~SslPolicyErrors.RemoteCertificateNameMismatch) == SslPolicyErrors.None,
        _ => errors == SslPolicyErrors.None,
    };

    /// <summary>
    /// The certificate check with a private CA: the chain must lead to that CA, which is trusted for this connection
    /// only and never added to the machine's store. The host name rule still follows the SSL mode.
    /// </summary>
    public static bool AcceptsCertificate(SslMode mode, SslPolicyErrors errors, X509Certificate2? authority, X509Certificate? certificate, X509Chain? chain)
    {
        if (mode == SslMode.Required)
        {
            return true;
        }

        if (authority is null || certificate is null)
        {
            return AcceptsCertificate(mode, errors);
        }

        if (mode == SslMode.VerifyIdentity && errors.HasFlag(SslPolicyErrors.RemoteCertificateNameMismatch))
        {
            return false;
        }

        using var custom = new X509Chain();
        custom.ChainPolicy.TrustMode = X509ChainTrustMode.CustomRootTrust;
        custom.ChainPolicy.CustomTrustStore.Add(authority);
        custom.ChainPolicy.RevocationMode = X509RevocationMode.NoCheck;
        if (chain is not null)
        {
            foreach (var element in chain.ChainElements)
            {
                custom.ChainPolicy.ExtraStore.Add(element.Certificate);
            }
        }

        if (certificate is X509Certificate2 typed)
        {
            return custom.Build(typed);
        }

        using var loaded = X509CertificateLoader.LoadCertificate(certificate.GetRawCertData());
        return custom.Build(loaded);
    }

    /// <summary>The database number from <c>3</c> or <c>db3</c>; empty means database 0.</summary>
    public static int ParseDatabaseIndex(string? text)
    {
        if (string.IsNullOrWhiteSpace(text))
        {
            return 0;
        }

        return TryParseDatabaseIndex(text, out var index)
            ? index
            : throw new ArgumentException($"'{text}' is not a Redis database number. Use a number such as 0 or a name such as db0.");
    }

    public static bool TryParseDatabaseIndex(string? text, out int index)
    {
        index = 0;
        if (string.IsNullOrWhiteSpace(text))
        {
            return false;
        }

        var span = text.AsSpan().Trim();
        if (span.StartsWith("db", StringComparison.OrdinalIgnoreCase))
        {
            span = span[2..];
        }

        return int.TryParse(span, NumberStyles.None, CultureInfo.InvariantCulture, out index);
    }

    public static string SchemaName(int index) => string.Create(CultureInfo.InvariantCulture, $"db{index}");

    /// <summary>The client library's own options from what is left once the driver's keys are taken out.</summary>
    private static ConfigurationOptions LibraryOptions(IReadOnlyDictionary<string, string> settings)
    {
        var extra = settings
            .Where(p => !string.IsNullOrWhiteSpace(p.Key) && !RedisTopologyKeys.All.Contains(p.Key.Trim()))
            .Select(p => $"{p.Key.Trim()}={p.Value}")
            .ToArray();
        return extra.Length == 0 ? new ConfigurationOptions() : ConfigurationOptions.Parse(string.Join(',', extra), ignoreUnknown: true);
    }

    /// <summary>
    /// Sentinels log in with the Sentinel fields only. Left empty, nothing is sent, as on macOS: a Sentinel without
    /// requirepass refuses an AUTH, so reusing the data password would fail where the data node's own login works.
    /// </summary>
    private static ConfigurationOptions SentinelOptions(IReadOnlyDictionary<string, string> settings, string group, int connectTimeout) => new()
    {
        ServiceName = group,
        User = RedisTopologyKeys.Read(settings, RedisTopologyKeys.SentinelUser),
        Password = RedisTopologyKeys.Read(settings, RedisTopologyKeys.SentinelPassword),
        ConnectTimeout = connectTimeout,
        AbortOnConnectFail = true,
        ClientName = ClientName,
    };

    private static IReadOnlyList<RedisNodeAddress> Nodes(IReadOnlyDictionary<string, string> settings, string[] keys, int defaultPort, string host, int port)
    {
        var nodes = RedisHostList.WithPrimary(RedisHostList.Parse(RedisTopologyKeys.Read(settings, keys), defaultPort), host, port);
        return nodes.Count > 0 ? nodes : throw new ArgumentException("List at least one node to connect to, as host:port.");
    }

    private static void ApplyTls(ConfigurationOptions options, IReadOnlyDictionary<string, string> settings, SslMode mode, string? hostName)
    {
        options.Ssl = UsesTls(mode);
        if (!options.Ssl)
        {
            return;
        }

        // Through an SSH tunnel the endpoint is 127.0.0.1, while the certificate names the host the user typed. With
        // several nodes each certificate names its own node, so the library checks each against its endpoint.
        if (hostName is not null)
        {
            options.SslHost ??= hostName;
        }

        var caPath = RedisTopologyKeys.Read(settings, RedisTopologyKeys.CaCertificate);
        var authority = caPath is null ? null : X509CertificateLoader.LoadCertificateFromFile(caPath);
        options.CertificateValidation += (_, certificate, chain, errors) => AcceptsCertificate(mode, errors, authority, certificate, chain);

        if (ClientCertificate(settings) is { } client)
        {
            options.CertificateSelection += (_, _, _, _, _) => client;
        }
    }

    /// <summary>A PEM certificate and key pair, or a PKCS#12 file when no key file is named.</summary>
    private static X509Certificate2? ClientCertificate(IReadOnlyDictionary<string, string> settings)
    {
        var certPath = RedisTopologyKeys.Read(settings, RedisTopologyKeys.ClientCertificate);
        if (certPath is null)
        {
            return null;
        }

        if (RedisTopologyKeys.Read(settings, RedisTopologyKeys.ClientKey) is not { } keyPath)
        {
            return X509CertificateLoader.LoadPkcs12FromFile(certPath, null);
        }

        // SChannel cannot use a key that lives only in memory, so the PEM pair goes through PKCS#12 first.
        using var pem = X509Certificate2.CreateFromPemFile(certPath, keyPath);
        return X509CertificateLoader.LoadPkcs12(pem.Export(X509ContentType.Pkcs12), null);
    }
}
