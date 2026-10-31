using System.Net;
using System.Net.Security;
using System.Security.Authentication;
using System.Security.Cryptography.X509Certificates;
using System.Text.RegularExpressions;
using Cassandra;
using Cassandra.Serialization;
using TablePro.Core.Drivers;
using TablePro.Drivers.Cassandra.Localization;
using CoreSslMode = TablePro.Core.Connections.SslMode;

namespace TablePro.Drivers.Cassandra;

/// <summary>
/// Everything a cluster is built from, read once from the connection request. Kept apart from the driver's
/// <see cref="Builder"/> so the choices (contact points, TLS, consistency, SigV4) are testable without a server.
/// </summary>
public sealed partial record CassandraConnectionSettings
{
    public const string ContactPointsOption = "contactPoints";
    public const string LocalDatacenterOption = "localDatacenter";
    public const string ConsistencyOption = "consistency";
    public const string AllowFilteringOption = "allowFiltering";
    public const string AwsAuthOption = "awsAuth";
    public const string AwsRegionOption = "awsRegion";
    public const string AwsAccessKeyIdOption = "awsAccessKeyId";
    public const string AwsSecretAccessKeyOption = "awsSecretAccessKey";
    public const string AwsSessionTokenOption = "awsSessionToken";

    private const int TlsOnlyPort = 9142;

    public required IReadOnlyList<string> ContactPoints { get; init; }

    public required int Port { get; init; }

    /// <summary>The request dials an SSH tunnel's local end, so only that one node is reachable.</summary>
    public required bool IsTunneled { get; init; }

    public string? LocalDatacenter { get; init; }

    public string? Keyspace { get; init; }

    public string? Username { get; init; }

    public string? Password { get; init; }

    public ConsistencyLevel ReadConsistency { get; init; } = ConsistencyLevel.LocalOne;

    public ConsistencyLevel WriteConsistency { get; init; } = ConsistencyLevel.LocalQuorum;

    public bool UseTls { get; init; }

    public CoreSslMode SslMode { get; init; }

    /// <summary>The name the server certificate is checked against: what the user typed, never the tunnel's loopback address.</summary>
    public string? TlsHostName { get; init; }

    public KeyspacesCredentials? SigV4 { get; init; }

    public int ConnectTimeoutMilliseconds { get; init; } = 15_000;

    public bool AllowFiltering { get; init; }

    public static CassandraConnectionSettings From(ConnectionRequest request)
    {
        var profile = request.Profile;
        var options = profile.AdditionalOptions;
        var isTunneled = !string.Equals(request.Host, profile.Host, StringComparison.OrdinalIgnoreCase) || request.Port != profile.EffectivePort;

        var contactPoints = new List<string> { request.Host };
        if (!isTunneled && Option(options, ContactPointsOption) is { } extra)
        {
            foreach (var point in extra.Split([',', ';', ' '], StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries))
            {
                if (!contactPoints.Contains(point, StringComparer.OrdinalIgnoreCase))
                {
                    contactPoints.Add(point);
                }
            }
        }

        var consistency = ParseConsistency(Option(options, ConsistencyOption));
        var sigV4 = ReadSigV4(request);
        var isKeyspaces = sigV4 is not null || IsKeyspacesEndpoint(profile.Host);

        // CQL has no STARTTLS, so "preferred" cannot fall back at runtime; it means TLS where the endpoint can only
        // speak TLS (Amazon Keyspaces, the conventional TLS port) and plain text elsewhere.
        var useTls = profile.SslMode switch
        {
            CoreSslMode.Disabled => false,
            CoreSslMode.Preferred => isKeyspaces || profile.EffectivePort == TlsOnlyPort,
            _ => true,
        };

        if (sigV4 is not null && !useTls)
        {
            throw new InvalidOperationException(CassandraStrings.Get("Cassandra/KeyspacesNeedsTls"));
        }

        return new CassandraConnectionSettings
        {
            ContactPoints = contactPoints,
            Port = request.Port,
            IsTunneled = isTunneled,
            LocalDatacenter = Option(options, LocalDatacenterOption),
            Keyspace = string.IsNullOrWhiteSpace(request.Database) ? null : request.Database.Trim(),
            Username = string.IsNullOrEmpty(profile.Username) ? null : profile.Username,
            Password = request.Password,
            ReadConsistency = consistency ?? ConsistencyLevel.LocalOne,
            WriteConsistency = consistency ?? ConsistencyLevel.LocalQuorum,
            UseTls = useTls,
            SslMode = profile.SslMode,
            TlsHostName = profile.Host,
            SigV4 = sigV4,
            ConnectTimeoutMilliseconds = Math.Max(profile.ConnectTimeoutSeconds, 1) * 1000,
            AllowFiltering = string.Equals(Option(options, AllowFilteringOption), "true", StringComparison.OrdinalIgnoreCase),
        };
    }

    /// <summary>Reads a consistency level by its CQL name. SERIAL levels apply only to lightweight transactions, so a connection never defaults to them.</summary>
    public static ConsistencyLevel? ParseConsistency(string? name)
    {
        if (string.IsNullOrWhiteSpace(name))
        {
            return null;
        }

        var normalized = name.Trim().Replace("_", string.Empty, StringComparison.Ordinal);
        if (Enum.TryParse<ConsistencyLevel>(normalized, ignoreCase: true, out var level)
            && Enum.IsDefined(level)
            && !char.IsAsciiDigit(normalized[0])
            && level is not (ConsistencyLevel.Serial or ConsistencyLevel.LocalSerial))
        {
            return level;
        }

        throw new ArgumentException(CassandraStrings.Format("Cassandra/BadConsistencyLevel", name));
    }

    public static string CqlName(ConsistencyLevel level) => level switch
    {
        ConsistencyLevel.LocalOne => "LOCAL_ONE",
        ConsistencyLevel.LocalQuorum => "LOCAL_QUORUM",
        ConsistencyLevel.EachQuorum => "EACH_QUORUM",
        ConsistencyLevel.LocalSerial => "LOCAL_SERIAL",
        _ => level.ToString().ToUpperInvariant(),
    };

    /// <summary>cassandra[-fips].region on amazonaws.com[.cn] or api.aws, and the VPC endpoint form.</summary>
    public static bool IsKeyspacesEndpoint(string host) => KeyspacesHost().IsMatch(host.Trim().TrimEnd('.'));

    public Builder CreateBuilder()
    {
        var builder = Cluster.Builder()
            .WithPort(Port)
            .WithApplicationName("TablePro")
            .WithQueryOptions(new QueryOptions().SetConsistencyLevel(ReadConsistency).SetPageSize(5000))
            .WithSocketOptions(new SocketOptions().SetConnectTimeoutMillis(ConnectTimeoutMilliseconds).SetReadTimeoutMillis(Math.Max(ConnectTimeoutMilliseconds, 12_000)))
            .WithTypeSerializers(new TypeSerializerDefinitions().Define(new CqlUdtSerializer()));

        foreach (var point in ContactPoints)
        {
            builder.AddContactPoint(point);
        }

        if (IsTunneled)
        {
            builder.WithLoadBalancingPolicy(new TunnelEndpointPolicy(Port));
        }
        else if (LocalDatacenter is not null)
        {
            builder.WithLoadBalancingPolicy(new DefaultLoadBalancingPolicy(LocalDatacenter));
        }

        if (SigV4 is not null)
        {
            builder.WithAuthProvider(new KeyspacesSigV4AuthProvider(SigV4));
        }
        else if (Username is not null)
        {
            builder.WithCredentials(Username, Password ?? string.Empty);
        }

        if (UseTls)
        {
            var hostName = TlsHostName;
            var ssl = new SSLOptions(SslProtocols.None, false, ValidateCertificate);
            if (!string.IsNullOrEmpty(hostName))
            {
                ssl.SetHostNameResolver(_ => hostName);
            }

            builder.WithSSL(ssl);
        }

        return builder;
    }

    internal bool ValidateCertificate(object sender, X509Certificate? certificate, X509Chain? chain, SslPolicyErrors errors) => SslMode switch
    {
        CoreSslMode.VerifyIdentity => errors == SslPolicyErrors.None,

        // The chain must lead to a trusted root; the name may differ, as with an IP address in the profile.
        CoreSslMode.VerifyCa => (errors & ~SslPolicyErrors.RemoteCertificateNameMismatch) == SslPolicyErrors.None,

        // Required and preferred encrypt without checking who answers, as the other platforms do.
        _ => true,
    };

    private static KeyspacesCredentials? ReadSigV4(ConnectionRequest request)
    {
        var options = request.Profile.AdditionalOptions;
        var mode = Option(options, AwsAuthOption);
        if (mode is null || mode.Equals("off", StringComparison.OrdinalIgnoreCase))
        {
            return null;
        }

        if (!mode.Equals("accessKey", StringComparison.OrdinalIgnoreCase) && !mode.Equals("sigv4", StringComparison.OrdinalIgnoreCase))
        {
            throw new NotSupportedException(CassandraStrings.Format("Cassandra/KeyspacesSignInUnavailable", mode));
        }

        var region = Option(options, AwsRegionOption) ?? RegionFromHost(request.Profile.Host)
            ?? throw new InvalidOperationException(CassandraStrings.Get("Cassandra/KeyspacesNeedsRegion"));
        var accessKey = Option(options, AwsAccessKeyIdOption) ?? request.Profile.Username;
        var secret = Option(options, AwsSecretAccessKeyOption) ?? request.Password;
        if (string.IsNullOrEmpty(accessKey) || string.IsNullOrEmpty(secret))
        {
            throw new InvalidOperationException(CassandraStrings.Get("Cassandra/KeyspacesNeedsAccessKey"));
        }

        return new KeyspacesCredentials(accessKey, secret, Option(options, AwsSessionTokenOption), region);
    }

    private static string? RegionFromHost(string host)
    {
        var match = KeyspacesHost().Match(host.Trim().TrimEnd('.'));
        return match.Success ? match.Groups["region"].Value : null;
    }

    private static string? Option(IReadOnlyDictionary<string, string> options, string key) =>
        options.TryGetValue(key, out var value) && !string.IsNullOrWhiteSpace(value) ? value.Trim() : null;

    [GeneratedRegex(@"(^|\.)cassandra(-fips)?\.(?<region>[a-z0-9-]+)\.(amazonaws\.com(\.cn)?|api\.aws|vpce\.amazonaws\.com)$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex KeyspacesHost();

    /// <summary>
    /// Keeps every request on the node behind the tunnel. The other nodes advertise addresses only reachable inside the
    /// cluster's network, so they are ignored rather than dialed and timed out on.
    /// </summary>
    private sealed class TunnelEndpointPolicy(int port) : ILoadBalancingPolicy
    {
        private ICluster? _cluster;

        public void Initialize(ICluster cluster) => _cluster = cluster;

        public HostDistance Distance(Host host) => IsTunnelEnd(host.Address) ? HostDistance.Local : HostDistance.Ignored;

        public IEnumerable<Host> NewQueryPlan(string keyspace, IStatement query) =>
            _cluster?.AllHosts().Where(h => IsTunnelEnd(h.Address)) ?? [];

        private bool IsTunnelEnd(IPEndPoint endpoint) => endpoint.Port == port && IPAddress.IsLoopback(endpoint.Address);
    }
}
