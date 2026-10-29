using System.Globalization;

namespace TablePro.Drivers.Redis;

/// <summary>How the connection reaches the data: one server, a primary that Sentinel names, or a Redis Cluster.</summary>
internal enum RedisConnectionMode
{
    Standalone,
    Sentinel,
    Cluster,
}

/// <summary>A node to dial, as a host list entry names it.</summary>
internal readonly record struct RedisNodeAddress(string Host, int Port)
{
    public override string ToString() =>
        Host.Contains(':', StringComparison.Ordinal)
            ? string.Create(CultureInfo.InvariantCulture, $"[{Host}]:{Port}")
            : string.Create(CultureInfo.InvariantCulture, $"{Host}:{Port}");
}

/// <summary>
/// The option keys the connection form's mode fields write. The <c>redis</c> prefixed names are the ones the macOS
/// app stores, so a profile moved between the apps keeps its mode; the short names are easier to type.
/// </summary>
internal static class RedisTopologyKeys
{
    public const int SentinelDefaultPort = 26379;
    public const int ClusterDefaultPort = 6379;
    public const string DefaultPrimaryGroup = "mymaster";

    public static readonly string[] Mode = ["redisMode", "mode"];
    public static readonly string[] SentinelHosts = ["redisSentinelHosts", "sentinelHosts"];
    public static readonly string[] PrimaryGroup = ["redisSentinelMasterName", "sentinelMasterName", "serviceName"];
    public static readonly string[] SentinelUser = ["redisSentinelUsername", "sentinelUsername", "sentinelUser"];
    public static readonly string[] SentinelPassword = ["redisSentinelPassword", "sentinelPassword"];
    public static readonly string[] ClusterHosts = ["redisClusterHosts", "clusterHosts"];
    public static readonly string[] CaCertificate = ["redisCaCertPath", "caCertPath"];
    public static readonly string[] ClientCertificate = ["redisClientCertPath", "clientCertPath"];
    public static readonly string[] ClientKey = ["redisClientKeyPath", "clientKeyPath"];

    /// <summary>What the sidebar splits key names at. Unlike the other keys an empty value means something: no tree.</summary>
    public const string Separator = "redisSeparator";

    /// <summary>
    /// Every key the driver reads itself. They stay out of the client library's option string, where a host list's
    /// commas would split into stray endpoints.
    /// </summary>
    public static readonly IReadOnlySet<string> All = new HashSet<string>(
        Mode.Concat(SentinelHosts).Concat(PrimaryGroup).Concat(SentinelUser).Concat(SentinelPassword)
            .Concat(ClusterHosts).Concat(CaCertificate).Concat(ClientCertificate).Concat(ClientKey)
            .Append("redisDatabase").Append(Separator),
        StringComparer.OrdinalIgnoreCase);

    public static string? Read(IReadOnlyDictionary<string, string> options, string[] keys)
    {
        foreach (var key in keys)
        {
            foreach (var (name, value) in options)
            {
                if (string.Equals(name.Trim(), key, StringComparison.OrdinalIgnoreCase) && !string.IsNullOrWhiteSpace(value))
                {
                    return value.Trim();
                }
            }
        }

        return null;
    }

    /// <summary>The key separator, empty when the profile asks for a flat list; the macOS default <c>:</c> when it names none.</summary>
    public static string ReadSeparator(IReadOnlyDictionary<string, string> options)
    {
        foreach (var (name, value) in options)
        {
            if (string.Equals(name.Trim(), Separator, StringComparison.OrdinalIgnoreCase))
            {
                return value;
            }
        }

        return ":";
    }

    public static RedisConnectionMode ResolveMode(IReadOnlyDictionary<string, string> options) =>
        Read(options, Mode)?.ToLowerInvariant() switch
        {
            "sentinel" => RedisConnectionMode.Sentinel,
            "cluster" => RedisConnectionMode.Cluster,
            null or "" or "standalone" or "single" => RedisConnectionMode.Standalone,
            var other => throw new ArgumentException($"'{other}' is not a Redis connection mode. Use standalone, sentinel or cluster."),
        };
}

/// <summary>Reads the comma separated node lists the Sentinel and Cluster fields hold.</summary>
internal static class RedisHostList
{
    /// <summary>
    /// Entries such as <c>10.0.0.1:26379</c>, <c>sentinel-a</c> (the default port) or <c>[::1]:6379</c>. An entry that
    /// cannot be read is an error rather than skipped, since a silently dropped seed looks like a cluster that is down.
    /// </summary>
    public static IReadOnlyList<RedisNodeAddress> Parse(string? text, int defaultPort)
    {
        if (string.IsNullOrWhiteSpace(text))
        {
            return [];
        }

        var nodes = new List<RedisNodeAddress>();
        foreach (var raw in text.Split([',', ';', '\n'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            nodes.Add(ParseEntry(raw, defaultPort) ?? throw new ArgumentException($"'{raw}' is not a host or host:port."));
        }

        return nodes;
    }

    public static RedisNodeAddress? ParseEntry(string entry, int defaultPort)
    {
        if (entry.Length == 0)
        {
            return null;
        }

        if (entry[0] == '[')
        {
            var closing = entry.IndexOf(']', StringComparison.Ordinal);
            if (closing <= 1)
            {
                return null;
            }

            var host = entry[1..closing];
            if (closing == entry.Length - 1)
            {
                return new RedisNodeAddress(host, defaultPort);
            }

            return entry[closing + 1] == ':' && ParsePort(entry[(closing + 2)..]) is { } bracketPort ? new RedisNodeAddress(host, bracketPort) : null;
        }

        // A bare IPv6 literal has several colons and no port, so only a single colon splits.
        var colon = entry.LastIndexOf(':');
        if (colon >= 0 && entry.IndexOf(':', StringComparison.Ordinal) == colon)
        {
            return colon > 0 && ParsePort(entry[(colon + 1)..]) is { } port ? new RedisNodeAddress(entry[..colon], port) : null;
        }

        return new RedisNodeAddress(entry, defaultPort);
    }

    /// <summary>
    /// The list, with the form's Host and Port added after it when the list does not already name them, so a single
    /// node typed in Host is enough and a longer list only adds to it.
    /// </summary>
    public static IReadOnlyList<RedisNodeAddress> WithPrimary(IReadOnlyList<RedisNodeAddress> listed, string host, int port)
    {
        if (string.IsNullOrWhiteSpace(host) || port <= 0)
        {
            return listed;
        }

        var primary = new RedisNodeAddress(host.Trim(), port);
        return listed.Any(n => string.Equals(n.Host, primary.Host, StringComparison.OrdinalIgnoreCase) && n.Port == primary.Port)
            ? listed
            : [.. listed, primary];
    }

    private static int? ParsePort(string text) =>
        int.TryParse(text, NumberStyles.None, CultureInfo.InvariantCulture, out var port) && port is >= 1 and <= 65535 ? port : null;
}

/// <summary>
/// Turns "pointed at the wrong kind of node" into a sentence naming the setting to change. A Sentinel port accepts the
/// connection and refuses every data command, and a cluster node answers MOVED, so both otherwise read as bugs.
/// </summary>
internal static class RedisTopologyDiagnostics
{
    public const string NotACluster =
        "This server is not running in cluster mode. Set the connection mode to standalone, or point cluster mode at a node started with cluster-enabled yes.";

    public const string SentinelThroughTunnel =
        "A tunnel forwards one address, and the node Sentinel names is on the server's own network, so Sentinel mode cannot run through one. Connect to a data node directly, or turn the tunnel off.";

    /// <summary>The kind of server an <c>INFO server</c> reply describes, or null when it says nothing about it.</summary>
    public static RedisConnectionMode? ModeFromInfo(string? info)
    {
        // Valkey 8 writes server_mode instead of redis_mode unless extended-redis-compatibility is on.
        var mode = RedisServerText.InfoValue(info, "redis_mode") ?? RedisServerText.InfoValue(info, "server_mode");
        return mode?.Trim().ToLowerInvariant() switch
        {
            "standalone" => RedisConnectionMode.Standalone,
            "sentinel" => RedisConnectionMode.Sentinel,
            "cluster" => RedisConnectionMode.Cluster,
            _ => null,
        };
    }

    /// <summary>
    /// Why the server that answered does not fit the chosen mode, or null when it does. A tunnel turns any mode into
    /// one forwarded node: a cluster node still serves its own slots there, while a Sentinel serves no data at all.
    /// </summary>
    public static string? Mismatch(RedisConnectionMode expected, RedisConnectionMode actual, bool tunneled)
    {
        if (tunneled)
        {
            return actual == RedisConnectionMode.Sentinel ? SentinelThroughTunnel : null;
        }

        return (expected, actual) switch
        {
            (RedisConnectionMode.Standalone, RedisConnectionMode.Cluster) =>
                "This server is part of a Redis Cluster, so requests for keys it does not own would fail. Set the connection mode to cluster and list this address among the cluster nodes.",
            (RedisConnectionMode.Standalone or RedisConnectionMode.Cluster, RedisConnectionMode.Sentinel) =>
                "This is a Redis Sentinel, not a data node, so it only answers SENTINEL commands. Set the connection mode to sentinel and list this address among the Sentinel nodes.",
            (RedisConnectionMode.Sentinel, RedisConnectionMode.Sentinel) =>
                "Sentinel resolved to another Sentinel rather than a data node. Check the primary group name in your Sentinel configuration.",
            (RedisConnectionMode.Cluster, RedisConnectionMode.Standalone) => NotACluster,
            _ => null,
        };
    }
}
