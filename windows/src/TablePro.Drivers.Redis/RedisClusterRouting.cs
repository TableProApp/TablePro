using System.Buffers;
using System.Collections.Frozen;
using System.Globalization;
using System.Text;

namespace TablePro.Drivers.Redis;

/// <summary>Redis Cluster hash slots: CRC16-XMODEM of the key, or of its <c>{tag}</c> when it has one, modulo 16384.</summary>
internal static class RedisKeySlot
{
    public const int SlotCount = 16384;

    public static int Slot(string key)
    {
        var length = Encoding.UTF8.GetByteCount(key);
        var rented = length > 256 ? ArrayPool<byte>.Shared.Rent(length) : null;
        try
        {
            Span<byte> bytes = rented ?? stackalloc byte[256];
            bytes = bytes[..Encoding.UTF8.GetBytes(key, bytes)];
            return Crc16(HashedRegion(bytes)) & (SlotCount - 1);
        }
        finally
        {
            if (rented is not null)
            {
                ArrayPool<byte>.Shared.Return(rented);
            }
        }
    }

    /// <summary>Elements whose keys share a slot, in the order each slot first appears, duplicates kept.</summary>
    public static IReadOnlyList<IReadOnlyList<T>> GroupBySlot<T>(IEnumerable<T> elements, Func<T, string> key)
    {
        var order = new List<List<T>>();
        var bySlot = new Dictionary<int, List<T>>();
        foreach (var element in elements)
        {
            var slot = Slot(key(element));
            if (!bySlot.TryGetValue(slot, out var group))
            {
                group = [];
                bySlot[slot] = group;
                order.Add(group);
            }

            group.Add(element);
        }

        return order;
    }

    // An empty tag ("{}") hashes the whole key, as the cluster specification says.
    private static ReadOnlySpan<byte> HashedRegion(ReadOnlySpan<byte> key)
    {
        var open = key.IndexOf((byte)'{');
        if (open < 0)
        {
            return key;
        }

        var close = key[(open + 1)..].IndexOf((byte)'}');
        return close > 0 ? key.Slice(open + 1, close) : key;
    }

    private static int Crc16(ReadOnlySpan<byte> bytes)
    {
        var crc = 0;
        foreach (var b in bytes)
        {
            crc ^= b << 8;
            for (var i = 0; i < 8; i++)
            {
                crc = (crc & 0x8000) != 0 ? ((crc << 1) ^ 0x1021) & 0xFFFF : (crc << 1) & 0xFFFF;
            }
        }

        return crc;
    }
}

/// <summary>The request_policy command tip: which nodes of a cluster a keyless or multi-key command goes to.</summary>
internal enum RedisRequestPolicy
{
    None,
    AllNodes,
    AllShards,
    MultiShard,
    Special,
}

/// <summary>The response_policy command tip: how the replies of several nodes become one.</summary>
internal enum RedisResponsePolicy
{
    None,
    OneSucceeded,
    AllSucceeded,
    AggLogicalAnd,
    AggLogicalOr,
    AggMin,
    AggMax,
    AggSum,
    Special,
}

/// <summary>Where a command runs in a cluster.</summary>
internal enum RedisClusterFanOut
{
    /// <summary>One node: the key's owner, or any primary for a keyless command.</summary>
    Single,

    /// <summary>Every primary, replies combined.</summary>
    EveryPrimary,

    /// <summary>Every node, replicas included, replies combined.</summary>
    EveryNode,

    /// <summary>Split by hash slot and sent to each slot's owner.</summary>
    KeyedShards,
}

/// <summary>
/// One command's key positions and cluster tips, as <c>COMMAND</c> reports them. Positions count the command name as
/// 0, a negative last key counts from the end, and the step is the distance between keys (2 for MSET's key, value).
/// </summary>
internal readonly record struct RedisCommandSpec(
    string Name,
    int FirstKey,
    int LastKey,
    int Step,
    bool IsWrite = false,
    RedisRequestPolicy Request = RedisRequestPolicy.None,
    RedisResponsePolicy Response = RedisResponsePolicy.None)
{
    public IReadOnlyList<int> KeyIndices(int argumentCount)
    {
        if (FirstKey <= 0 || Step <= 0 || argumentCount <= FirstKey)
        {
            return [];
        }

        var last = LastKey < 0 ? argumentCount + LastKey : Math.Min(LastKey, argumentCount - 1);
        if (last < FirstKey)
        {
            return [];
        }

        var indices = new List<int>(((last - FirstKey) / Step) + 1);
        for (var i = FirstKey; i <= last; i += Step)
        {
            indices.Add(i);
        }

        return indices;
    }

    /// <summary>
    /// A special response has no rule for combining answers, so such a command goes to one node whatever its request
    /// policy says: gluing each node's <c>INFO</c> together would label none of them.
    /// </summary>
    public RedisClusterFanOut FanOut => Request switch
    {
        RedisRequestPolicy.AllNodes when Response != RedisResponsePolicy.Special => RedisClusterFanOut.EveryNode,
        RedisRequestPolicy.AllShards when Response != RedisResponsePolicy.Special => RedisClusterFanOut.EveryPrimary,
        RedisRequestPolicy.MultiShard => RedisClusterFanOut.KeyedShards,
        _ => RedisClusterFanOut.Single,
    };
}

/// <summary>
/// The key positions and cluster tips of the commands people type, as Redis 8 reports them. A command missing here
/// runs on one node and the client library follows any MOVED reply to the key's owner.
/// </summary>
internal static class RedisCommandRouting
{
    private static readonly FrozenDictionary<string, RedisCommandSpec> Specs = Build();

    /// <summary>The most specific entry: a container's subcommand (<c>config|set</c>) first, then the container.</summary>
    public static RedisCommandSpec? Spec(IReadOnlyList<string> words)
    {
        if (words.Count == 0)
        {
            return null;
        }

        var name = words[0].ToLowerInvariant();
        if (words.Count > 1 && Specs.TryGetValue(name + "|" + words[1].ToLowerInvariant(), out var nested))
        {
            return nested;
        }

        return Specs.TryGetValue(name, out var spec) ? spec : null;
    }

    /// <summary>
    /// The words of a command that are keys: the static positions, or for a command whose keys move with its
    /// arguments (EVAL's numkeys, XREAD's STREAMS) what COMMAND GETKEYS would answer, read from those arguments.
    /// </summary>
    public static IReadOnlyList<int> KeyIndices(IReadOnlyList<string> words)
    {
        if (words.Count == 0)
        {
            return [];
        }

        return words[0].ToLowerInvariant() switch
        {
            "eval" or "evalsha" or "eval_ro" or "evalsha_ro" or "fcall" or "fcall_ro" => Counted(words, 2),
            "lmpop" or "zmpop" or "sintercard" or "zdiff" or "zunion" or "zinter" => Counted(words, 1),
            "zunionstore" or "zinterstore" or "zdiffstore" => words.Count > 1 ? [1, .. Counted(words, 2)] : [],
            "xread" or "xreadgroup" => Streams(words),
            _ => Spec(words) is { } spec ? spec.KeyIndices(words.Count) : [],
        };
    }

    private static readonly FrozenSet<string> NodeVerbs = FrozenSet.Create(StringComparer.OrdinalIgnoreCase,
        ["CLIENT", "INFO", "CONFIG", "SLOWLOG", "MEMORY", "LATENCY", "ROLE", "TIME", "LASTSAVE", "DEBUG", "ACL", "COMMAND", "MODULE",
         "CLUSTER", "ECHO", "PING", "LOLWUT", "SAVE", "BGSAVE", "BGREWRITEAOF", "SCRIPT", "FUNCTION", "PUBSUB", "READONLY", "READWRITE"]);

    /// <summary>
    /// Whether a keyless command describes or changes the node it reaches, such as CLIENT LIST, so it belongs on one
    /// chosen node. Any other command without known keys may hold keys this table does not know, and goes where the
    /// client library sends it, which follows a MOVED reply to the owner.
    /// </summary>
    public static bool IsNodeCommand(IReadOnlyList<string> words) => words.Count > 0 && NodeVerbs.Contains(words[0]);

    /// <summary>The hash slots a command's keys fall in, each once.</summary>
    public static IReadOnlySet<int> Slots(IReadOnlyList<string> words) =>
        KeyIndices(words).Select(i => RedisKeySlot.Slot(words[i])).ToHashSet();

    /// <summary>A numkeys argument at <paramref name="countAt"/> followed by that many keys.</summary>
    private static int[] Counted(IReadOnlyList<string> words, int countAt)
    {
        if (words.Count <= countAt || !int.TryParse(words[countAt], NumberStyles.None, CultureInfo.InvariantCulture, out var count))
        {
            return [];
        }

        var available = Math.Min(count, words.Count - countAt - 1);
        return Enumerable.Range(countAt + 1, Math.Max(0, available)).ToArray();
    }

    /// <summary>After STREAMS come the keys and then as many ids, so the keys are the first half of what follows.</summary>
    private static int[] Streams(IReadOnlyList<string> words)
    {
        for (var i = 1; i < words.Count; i++)
        {
            if (words[i].Equals("STREAMS", StringComparison.OrdinalIgnoreCase))
            {
                var rest = words.Count - i - 1;
                return rest % 2 == 0 ? Enumerable.Range(i + 1, rest / 2).ToArray() : [];
            }
        }

        return [];
    }

    private static FrozenDictionary<string, RedisCommandSpec> Build()
    {
        var table = new Dictionary<string, RedisCommandSpec>(StringComparer.Ordinal);
        void Add(RedisCommandSpec spec) => table[spec.Name] = spec;

        foreach (var name in (string[])["get", "strlen", "type", "ttl", "pttl", "expiretime", "dump", "hgetall", "hkeys", "hvals", "hlen",
                     "llen", "lrange", "lindex", "smembers", "scard", "srandmember", "sismember", "smismember", "zcard", "zscore", "zmscore",
                     "zrange", "zrangebyscore", "zrangebylex", "zrevrange", "zrevrangebyscore", "zcount", "zlexcount", "zrank",
                     "zrevrank", "xrange", "xrevrange", "xlen", "hget", "hmget", "hexists", "hstrlen", "hrandfield",
                     "hscan", "sscan", "zscan", "lpos", "getrange", "getbit", "bitcount", "bitpos", "pfcount", "geopos", "geodist", "geohash",
                     "geosearch", "json.get", "json.type", "json.strlen", "json.arrlen", "json.objkeys", "ts.get", "ts.range", "xpending"])
        {
            Add(new(name, 1, 1, 1));
        }

        foreach (var name in (string[])["set", "getset", "getdel", "getex", "append", "setrange", "incr", "decr", "incrby",
                     "decrby", "incrbyfloat", "expire", "pexpire", "expireat", "pexpireat", "persist",
                     "hset", "hsetnx", "hmset", "hdel", "hincrby", "hincrbyfloat", "lpush", "rpush", "lpushx",
                     "rpushx", "lpop", "rpop", "lset", "linsert", "lrem", "ltrim", "sadd", "srem",
                     "spop", "zadd", "zrem", "zincrby", "zpopmin", "zpopmax", "zremrangebyscore", "zremrangebyrank", "zremrangebylex",
                     "xadd", "xdel", "xtrim", "xack", "xclaim",
                     "setex", "psetex", "setnx", "restore", "setbit", "pfadd", "geoadd", "json.set", "json.del", "json.arrappend",
                     "json.numincrby", "ts.add", "ts.create"])
        {
            Add(new(name, 1, 1, 1, IsWrite: true));
        }

        foreach (var name in (string[])["xinfo|stream", "xinfo|groups", "xinfo|consumers"])
        {
            Add(new(name, 2, 2, 1));
        }

        foreach (var name in (string[])["xgroup|create", "xgroup|destroy", "xgroup|setid", "xgroup|createconsumer", "xgroup|delconsumer"])
        {
            Add(new(name, 2, 2, 1, IsWrite: true));
        }

        foreach (var name in (string[])["rename", "renamenx", "smove", "lmove", "rpoplpush", "copy"])
        {
            Add(new(name, 1, 2, 1, IsWrite: true));
        }

        Add(new("mget", 1, -1, 1, Request: RedisRequestPolicy.MultiShard));
        Add(new("json.mget", 1, -2, 1));
        Add(new("mset", 1, -1, 2, IsWrite: true, Request: RedisRequestPolicy.MultiShard, Response: RedisResponsePolicy.AllSucceeded));
        Add(new("msetnx", 1, -1, 2, IsWrite: true));
        foreach (var name in (string[])["del", "unlink"])
        {
            Add(new(name, 1, -1, 1, IsWrite: true, Request: RedisRequestPolicy.MultiShard, Response: RedisResponsePolicy.AggSum));
        }

        Add(new("exists", 1, -1, 1, Request: RedisRequestPolicy.MultiShard, Response: RedisResponsePolicy.AggSum));
        Add(new("touch", 1, -1, 1, Request: RedisRequestPolicy.MultiShard, Response: RedisResponsePolicy.AggSum));
        foreach (var name in (string[])["sunion", "sinter", "sdiff", "pfmerge"])
        {
            Add(new(name, 1, -1, 1));
        }

        foreach (var name in (string[])["sunionstore", "sinterstore", "sdiffstore"])
        {
            Add(new(name, 1, -1, 1, IsWrite: true));
        }

        Add(new("object|encoding", 2, 2, 1));
        Add(new("object|refcount", 2, 2, 1));
        Add(new("object|idletime", 2, 2, 1));
        Add(new("object|freq", 2, 2, 1));
        Add(new("memory|usage", 2, 2, 1));

        Add(new("keys", 0, 0, 0, Request: RedisRequestPolicy.AllShards));
        Add(new("dbsize", 0, 0, 0, Request: RedisRequestPolicy.AllShards, Response: RedisResponsePolicy.AggSum));
        Add(new("flushdb", 0, 0, 0, IsWrite: true, Request: RedisRequestPolicy.AllShards, Response: RedisResponsePolicy.AllSucceeded));
        Add(new("flushall", 0, 0, 0, IsWrite: true, Request: RedisRequestPolicy.AllShards, Response: RedisResponsePolicy.AllSucceeded));
        Add(new("info", 0, 0, 0, Request: RedisRequestPolicy.AllShards, Response: RedisResponsePolicy.Special));
        Add(new("randomkey", 0, 0, 0, Request: RedisRequestPolicy.AllShards, Response: RedisResponsePolicy.Special));
        Add(new("scan", 0, 0, 0, Request: RedisRequestPolicy.Special, Response: RedisResponsePolicy.Special));
        Add(new("ping", 0, 0, 0, Request: RedisRequestPolicy.AllShards, Response: RedisResponsePolicy.AllSucceeded));
        Add(new("config|set", 0, 0, 0, Request: RedisRequestPolicy.AllNodes, Response: RedisResponsePolicy.AllSucceeded));
        Add(new("config|resetstat", 0, 0, 0, Request: RedisRequestPolicy.AllNodes, Response: RedisResponsePolicy.AllSucceeded));
        Add(new("script|load", 0, 0, 0, Request: RedisRequestPolicy.AllNodes, Response: RedisResponsePolicy.AllSucceeded));
        Add(new("script|flush", 0, 0, 0, Request: RedisRequestPolicy.AllNodes, Response: RedisResponsePolicy.AllSucceeded));
        Add(new("script|exists", 0, 0, 0, Request: RedisRequestPolicy.AllShards, Response: RedisResponsePolicy.AggLogicalAnd));
        Add(new("memory|stats", 0, 0, 0, Request: RedisRequestPolicy.AllShards, Response: RedisResponsePolicy.Special));
        Add(new("slowlog|get", 0, 0, 0, Request: RedisRequestPolicy.AllNodes));
        Add(new("ft._list", 0, 0, 0));
        return table.ToFrozenDictionary(StringComparer.Ordinal);
    }
}

/// <summary>One slot's share of a multi-key command, and where its keys sat in the original command.</summary>
internal sealed record RedisShardPart(int Slot, IReadOnlyList<string> Words, IReadOnlyList<int> KeyIndices);

/// <summary>
/// Splits a multi-key command by hash slot and puts the answers back together. The split follows slots, not nodes:
/// two slots on one node today can be apart tomorrow, and Redis refuses a command whose keys span slots either way.
/// Multiplicity is kept, since <c>EXISTS a a a</c> is 3.
/// </summary>
internal static class RedisMultiShardPlanner
{
    /// <summary>The parts, or null when every key is in one slot and the command can run whole.</summary>
    public static IReadOnlyList<RedisShardPart>? Split(IReadOnlyList<string> words, RedisCommandSpec spec)
    {
        var keyIndices = spec.KeyIndices(words.Count);
        if (keyIndices.Count < 2)
        {
            return null;
        }

        var prefix = words.Take(spec.FirstKey).ToArray();
        var order = new List<int>();
        var units = new Dictionary<int, List<string>>();
        var indices = new Dictionary<int, List<int>>();
        foreach (var index in keyIndices)
        {
            var slot = RedisKeySlot.Slot(words[index]);
            if (!units.TryGetValue(slot, out var unit))
            {
                unit = [];
                units[slot] = unit;
                indices[slot] = [];
                order.Add(slot);
            }

            for (var i = index; i < Math.Min(index + spec.Step, words.Count); i++)
            {
                unit.Add(words[i]);
            }

            indices[slot].Add(index);
        }

        if (order.Count < 2)
        {
            return null;
        }

        return order.Select(slot => new RedisShardPart(slot, [.. prefix, .. units[slot]], indices[slot])).ToArray();
    }

    /// <summary>
    /// The no-policy rule for a keyed command (MGET): one element per input key, in the order asked. A part that
    /// failed has no elements to scatter, so its error is the answer rather than a run of nils.
    /// </summary>
    public static RedisReply ScatterInKeyOrder(IReadOnlyList<RedisShardPart> parts, IReadOnlyList<RedisReply> replies, IReadOnlyList<int> keyIndices)
    {
        if (parts.Count != replies.Count)
        {
            return RedisReply.Array(replies);
        }

        if (replies.FirstOrDefault(r => r.Kind == RedisReplyKind.Error) is { } failure)
        {
            return failure;
        }

        var byIndex = new Dictionary<int, RedisReply>();
        for (var p = 0; p < parts.Count; p++)
        {
            var items = replies[p].Items;
            for (var k = 0; k < parts[p].KeyIndices.Count && k < items.Count; k++)
            {
                byIndex[parts[p].KeyIndices[k]] = items[k];
            }
        }

        return RedisReply.Array(keyIndices.Select(i => byIndex.GetValueOrDefault(i) ?? RedisReply.Nil).ToArray());
    }
}

/// <summary>Combines the replies a fanned-out command collected, following its response policy.</summary>
internal static class RedisClusterAggregator
{
    /// <summary>
    /// A node that refused its part wins over every policy but one_succeeded: folding the error in as zero would
    /// report part of the keyspace as all of it.
    /// </summary>
    public static RedisReply Combine(IReadOnlyList<RedisReply> replies, RedisResponsePolicy policy)
    {
        if (replies.Count == 0)
        {
            return RedisReply.Array();
        }

        if (replies.Count == 1)
        {
            return replies[0];
        }

        if (policy != RedisResponsePolicy.OneSucceeded && replies.FirstOrDefault(r => r.Kind == RedisReplyKind.Error) is { } failure)
        {
            return failure;
        }

        return policy switch
        {
            RedisResponsePolicy.AggSum => Aggregated(replies, values => values.Sum()),
            RedisResponsePolicy.AggMin => Aggregated(replies, values => values.Min()),
            RedisResponsePolicy.AggMax => Aggregated(replies, values => values.Max()),
            RedisResponsePolicy.AggLogicalAnd => Aggregated(replies, values => values.All(v => v != 0) ? 1 : 0),
            RedisResponsePolicy.AggLogicalOr => Aggregated(replies, values => values.Any(v => v != 0) ? 1 : 0),
            RedisResponsePolicy.OneSucceeded => replies.FirstOrDefault(r => r.Kind != RedisReplyKind.Error) ?? replies[0],
            RedisResponsePolicy.AllSucceeded => replies[0],
            _ => Concatenated(replies),
        };
    }

    // A reply the policy cannot count is handed back whole rather than as a number made up for it.
    private static RedisReply Aggregated(IReadOnlyList<RedisReply> replies, Func<IReadOnlyList<long>, long> reduce) =>
        Folded(replies, reduce) ?? RedisReply.Array(replies);

    /// <summary>Integers fold to one; arrays of one width fold position by position (SCRIPT EXISTS, one flag per script).</summary>
    private static RedisReply? Folded(IReadOnlyList<RedisReply> replies, Func<IReadOnlyList<long>, long> reduce)
    {
        var numbers = new List<long>(replies.Count);
        foreach (var reply in replies)
        {
            if (reply.IsAggregate || !long.TryParse(reply.Text, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var value))
            {
                break;
            }

            numbers.Add(value);
        }

        if (numbers.Count == replies.Count)
        {
            return RedisReply.Integer(reduce(numbers));
        }

        if (!replies.All(r => r.Kind == RedisReplyKind.Array) || replies.Select(r => r.Items.Count).Distinct().Count() != 1)
        {
            return null;
        }

        var width = replies[0].Items.Count;
        var elements = new RedisReply[width];
        for (var i = 0; i < width; i++)
        {
            var position = i;
            if (Folded(replies.Select(r => r.Items[position]).ToArray(), reduce) is not { } element)
            {
                return null;
            }

            elements[i] = element;
        }

        return RedisReply.Array(elements);
    }

    /// <summary>The no-policy rule for a keyless fan-out (KEYS): every node's elements in one array.</summary>
    private static RedisReply Concatenated(IReadOnlyList<RedisReply> replies)
    {
        if (!replies.Any(r => r.IsAggregate))
        {
            return replies[0];
        }

        var merged = new List<RedisReply>();
        foreach (var reply in replies)
        {
            if (reply.IsAggregate)
            {
                merged.AddRange(reply.Items);
            }
            else if (!reply.IsNull)
            {
                merged.Add(reply);
            }
        }

        return RedisReply.Array(merged);
    }
}

/// <summary>
/// SCAN across a cluster walks each primary in turn, so the cursor names the node as well as where that node got to.
/// It names the node by address rather than by position: Redis accepts another node's cursor without complaint, so a
/// slipped index would lose keys silently, while an address no longer in the topology is detectable and restarts.
/// </summary>
internal static class RedisClusterCursor
{
    public const string Start = "0";

    /// <summary>The node to scan and its own cursor; null once every node is done. Restarted means keys may be missed.</summary>
    public static (string Node, string Cursor, bool Restarted)? Decode(string raw, IReadOnlyList<string> nodes)
    {
        if (nodes.Count == 0)
        {
            return null;
        }

        var trimmed = raw.Trim();
        if (trimmed.Length == 0 || trimmed == Start)
        {
            return (nodes[0], Start, false);
        }

        // A host name can hold a hyphen and the node's own cursor never does, so the split comes from the right.
        var separator = trimmed.LastIndexOf('-');
        if (separator <= 0 || separator == trimmed.Length - 1)
        {
            return (nodes[0], Start, true);
        }

        var node = trimmed[..separator];
        return nodes.Contains(node, StringComparer.OrdinalIgnoreCase)
            ? (nodes.First(n => string.Equals(n, node, StringComparison.OrdinalIgnoreCase)), trimmed[(separator + 1)..], false)
            : (nodes[0], Start, true);
    }

    /// <summary>The cursor to hand back after <paramref name="node"/> answered: on to the next node when it finished.</summary>
    public static string Advance(string node, string nodeCursor, IReadOnlyList<string> nodes)
    {
        if (nodeCursor != Start)
        {
            return node + "-" + nodeCursor;
        }

        var index = nodes.ToList().FindIndex(n => string.Equals(n, node, StringComparison.OrdinalIgnoreCase));
        return index >= 0 && index + 1 < nodes.Count ? nodes[index + 1] + "-" + Start : Start;
    }
}
