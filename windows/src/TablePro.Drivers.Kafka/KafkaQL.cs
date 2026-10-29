using System.Globalization;
using System.Text;
using TablePro.Core.Localization;
using TablePro.Drivers.Kafka.Localization;

namespace TablePro.Drivers.Kafka;

/// <summary>A KafkaQL statement the parser could not read.</summary>
public sealed class KafkaQLException : Exception
{
    public KafkaQLException()
    {
    }

    public KafkaQLException(string message)
        : base(message)
    {
    }

    public KafkaQLException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}

/// <summary>Where a consume starts. Kafka has no ORDER BY or skip-N, so a read is an anchor plus a direction.</summary>
internal enum KafkaStartKind
{
    /// <summary>The most recent messages, read backward from the end of each partition.</summary>
    Newest,

    /// <summary>The oldest messages the log still holds.</summary>
    Oldest,

    /// <summary>A literal offset, applied to every partition read.</summary>
    Offset,

    /// <summary>The first message at or after a time, in milliseconds since the epoch.</summary>
    Timestamp,

    /// <summary>Per-partition start offsets, read forward.</summary>
    Anchor,

    /// <summary>Per-partition exclusive end offsets, read backward.</summary>
    Tail,
}

internal sealed record KafkaStart(KafkaStartKind Kind, long Value = 0, IReadOnlyDictionary<int, long>? Offsets = null)
{
    public static readonly KafkaStart Newest = new(KafkaStartKind.Newest);

    public static readonly KafkaStart Oldest = new(KafkaStartKind.Oldest);

    public bool ReadsBackward => Kind is KafkaStartKind.Newest or KafkaStartKind.Tail;
}

internal abstract record KafkaStatement;

internal sealed record KafkaConsume(string Topic, KafkaStart Start, int Limit, int Skip, IReadOnlyList<int>? Partitions) : KafkaStatement;

internal sealed record KafkaProduce(string Topic, int? Partition, string? Key, string? Value, IReadOnlyList<KeyValuePair<string, string>> Headers) : KafkaStatement;

internal enum KafkaShowTarget
{
    Topics,
    Brokers,
    Groups,
    Cluster,
}

internal sealed record KafkaShow(KafkaShowTarget Target) : KafkaStatement;

internal sealed record KafkaDescribeTopic(string Topic) : KafkaStatement;

internal sealed record KafkaDescribeGroup(string Group) : KafkaStatement;

/// <summary>A new topic; -1 partitions or replication leaves the broker's default.</summary>
internal sealed record KafkaCreateTopic(string Topic, int Partitions, short Replication, IReadOnlyDictionary<string, string> Config) : KafkaStatement;

internal sealed record KafkaDropTopic(string Topic) : KafkaStatement;

/// <summary>
/// KafkaQL, the macOS app's command language for topics and groups. Kafka has no textual query language, so the
/// same small grammar serves the editor and what the grid runs:
/// <code>
/// CONSUME topic [FROM NEWEST|OLDEST|OFFSET n|TIME t|ANCHOR(p:o,..)|TAIL(p:o,..)] [PARTITION p[,p]] [LIMIT n] [SKIP n]
/// TAIL topic [PARTITION p] [LIMIT n]
/// PRODUCE topic [PARTITION p] [KEY k] [VALUE v] [HEADER name=value]...
/// SHOW TOPICS|BROKERS|GROUPS|CLUSTER
/// DESCRIBE TOPIC name | DESCRIBE GROUP name
/// CREATE TOPIC name [PARTITIONS n] [REPLICATION n] [CONFIG key=value]...
/// DROP TOPIC name
/// </code>
/// </summary>
internal static class KafkaQL
{
    /// <summary>LIMIT and SKIP share the reader's over-fetch ceiling: past it a page could not be honoured anyway.</summary>
    public const int MaximumLimit = 50_000;

    public const int DefaultLimit = 100;

    public static KafkaStatement Parse(string input)
    {
        var tokens = Tokenizer.Tokenize(input);
        var head = tokens.Next()?.ToUpperInvariant() ?? throw new KafkaQLException(KafkaStrings.Get("Kafka/EmptyStatement"));
        return head switch
        {
            "CONSUME" or "SELECT" => ParseConsume(tokens, KafkaStart.Oldest),
            "TAIL" => ParseTail(tokens),
            "PRODUCE" => ParseProduce(tokens),
            "SHOW" => ParseShow(tokens),
            "DESCRIBE" or "DESC" => ParseDescribe(tokens),
            "CREATE" => ParseCreate(tokens),
            "DROP" => ParseDrop(tokens),
            _ => throw new KafkaQLException(KafkaStrings.Format("Kafka/NotACommand", head)),
        };
    }

    /// <summary>Wraps a value so the tokenizer gives back exactly what went in.</summary>
    public static string Quote(string value) =>
        "\"" + value.Replace("\\", "\\\\", StringComparison.Ordinal).Replace("\"", "\\\"", StringComparison.Ordinal) + "\"";

    /// <summary>Strips the quotes and undoes the escaping <see cref="Quote"/> applies.</summary>
    public static string Unquote(string value)
    {
        if (value.Length < 2 || value[0] != value[^1] || value[0] is not ('"' or '\'' or '`'))
        {
            return value;
        }

        var inner = value.AsSpan(1, value.Length - 2);
        if (!inner.Contains('\\'))
        {
            return inner.ToString();
        }

        var text = new StringBuilder(inner.Length);
        var escaping = false;
        foreach (var c in inner)
        {
            if (escaping)
            {
                text.Append(c);
                escaping = false;
            }
            else if (c == '\\')
            {
                escaping = true;
            }
            else
            {
                text.Append(c);
            }
        }

        if (escaping)
        {
            text.Append('\\');
        }

        return text.ToString();
    }

    private static KafkaConsume ParseConsume(Tokenizer tokens, KafkaStart start)
    {
        // SELECT * FROM topic is accepted so the habit transfers, but there are no projections and no WHERE.
        if (tokens.Peek() == "*")
        {
            tokens.Next();
        }

        if (string.Equals(tokens.Peek(), "FROM", StringComparison.OrdinalIgnoreCase))
        {
            tokens.Next();
        }

        var topic = Unquote(tokens.Next() ?? throw new KafkaQLException(KafkaStrings.Format("Kafka/NeedsTopicName", "CONSUME")));
        var limit = DefaultLimit;
        var skip = 0;
        IReadOnlyList<int>? partitions = null;
        while (tokens.Next()?.ToUpperInvariant() is { } keyword)
        {
            switch (keyword)
            {
                case "FROM":
                    start = ParseStart(tokens);
                    break;
                case "LIMIT":
                    limit = Integer(tokens, "LIMIT");
                    break;
                case "SKIP" or "OFFSET":
                    skip = Integer(tokens, keyword);
                    break;
                case "PARTITION" or "PARTITIONS":
                    partitions = PartitionList(tokens);
                    break;
                default:
                    throw new KafkaQLException(KafkaStrings.Format("Kafka/Unexpected", keyword, "CONSUME"));
            }
        }

        Bounds(limit, skip);
        return new KafkaConsume(topic, start, limit, skip, partitions);
    }

    private static KafkaConsume ParseTail(Tokenizer tokens)
    {
        var topic = Unquote(tokens.Next() ?? throw new KafkaQLException(KafkaStrings.Format("Kafka/NeedsTopicName", "TAIL")));
        var limit = DefaultLimit;
        IReadOnlyList<int>? partitions = null;
        while (tokens.Next()?.ToUpperInvariant() is { } keyword)
        {
            switch (keyword)
            {
                case "LIMIT":
                    limit = Integer(tokens, "LIMIT");
                    break;
                case "PARTITION" or "PARTITIONS":
                    partitions = PartitionList(tokens);
                    break;
                default:
                    throw new KafkaQLException(KafkaStrings.Format("Kafka/UnexpectedInTail", keyword));
            }
        }

        Bounds(limit, 0);
        return new KafkaConsume(topic, KafkaStart.Newest, limit, 0, partitions);
    }

    private static void Bounds(int limit, int skip)
    {
        if (limit is <= 0 or > MaximumLimit)
        {
            throw new KafkaQLException(KafkaStrings.Format("Kafka/RangeBetween", "LIMIT", 1, MaximumLimit));
        }

        if (skip is < 0 or > MaximumLimit)
        {
            throw new KafkaQLException(KafkaStrings.Format("Kafka/RangeBetween", "SKIP", 0, MaximumLimit));
        }
    }

    private static KafkaStart ParseStart(Tokenizer tokens)
    {
        var mode = tokens.Next()?.ToUpperInvariant() ?? throw new KafkaQLException(KafkaStrings.Get("Kafka/FromNeeds"));

        // ANCHOR(0:1,1:2) arrives as one token, since the list sits in parentheses right after the word.
        string? list = null;
        var paren = mode.IndexOf('(', StringComparison.Ordinal);
        if (paren > 0)
        {
            list = mode[paren..];
            mode = mode[..paren];
        }

        return mode switch
        {
            "NEWEST" or "LATEST" or "END" => KafkaStart.Newest,
            "OLDEST" or "EARLIEST" or "BEGINNING" or "START" => KafkaStart.Oldest,
            "OFFSET" => new KafkaStart(KafkaStartKind.Offset, LongValue(tokens, "OFFSET")),
            "TIME" or "TIMESTAMP" => new KafkaStart(KafkaStartKind.Timestamp, Timestamp(tokens)),
            "ANCHOR" => new KafkaStart(KafkaStartKind.Anchor, 0, OffsetMap(list ?? tokens.Next(), "ANCHOR")),
            "TAIL" => new KafkaStart(KafkaStartKind.Tail, 0, OffsetMap(list ?? tokens.Next(), "TAIL")),
            _ => throw new KafkaQLException(KafkaStrings.Format("Kafka/NotStartPosition", mode)),
        };
    }

    private static KafkaProduce ParseProduce(Tokenizer tokens)
    {
        if (string.Equals(tokens.Peek(), "INTO", StringComparison.OrdinalIgnoreCase))
        {
            tokens.Next();
        }

        var topic = Unquote(tokens.Next() ?? throw new KafkaQLException(KafkaStrings.Format("Kafka/NeedsTopicName", "PRODUCE")));
        int? partition = null;
        string? key = null;
        string? value = null;
        var headers = new List<KeyValuePair<string, string>>();
        while (tokens.Next()?.ToUpperInvariant() is { } keyword)
        {
            switch (keyword)
            {
                case "KEY":
                    key = Unquote(Required(tokens, "KEY"));
                    break;
                case "VALUE" or "PAYLOAD":
                    value = Unquote(Required(tokens, keyword));
                    break;
                case "PARTITION":
                    partition = Integer(tokens, "PARTITION");
                    break;
                case "HEADER":
                    var first = Required(tokens, "HEADER");
                    if (SplitAssignment(first) is { } pair)
                    {
                        headers.Add(pair);
                    }
                    else
                    {
                        headers.Add(new(Unquote(first), Unquote(Required(tokens, "HEADER"))));
                    }

                    break;
                default:
                    throw new KafkaQLException(KafkaStrings.Format("Kafka/Unexpected", keyword, "PRODUCE"));
            }
        }

        if (key is null && value is null)
        {
            throw new KafkaQLException(KafkaStrings.Get("Kafka/ProduceNeedsValueOrKey"));
        }

        return new KafkaProduce(topic, partition, key, value, headers);
    }

    private static KafkaShow ParseShow(Tokenizer tokens)
    {
        var what = tokens.Next()?.ToUpperInvariant() ?? throw new KafkaQLException(KafkaStrings.Get("Kafka/ShowNeeds"));
        var target = what switch
        {
            "TOPICS" => KafkaShowTarget.Topics,
            "BROKERS" => KafkaShowTarget.Brokers,
            "GROUPS" or "CONSUMERS" => KafkaShowTarget.Groups,
            "CLUSTER" => KafkaShowTarget.Cluster,
            _ => throw new KafkaQLException(KafkaStrings.Format("Kafka/ShowUnsupported", what)),
        };
        End(tokens, "SHOW " + what);
        return new KafkaShow(target);
    }

    private static KafkaStatement ParseDescribe(Tokenizer tokens)
    {
        var what = tokens.Next()?.ToUpperInvariant() ?? throw new KafkaQLException(KafkaStrings.Get("Kafka/DescribeNeeds"));
        if (what is not ("TOPIC" or "GROUP"))
        {
            throw new KafkaQLException(KafkaStrings.Format("Kafka/DescribeUnsupported", what));
        }

        var name = Unquote(tokens.Next() ?? throw new KafkaQLException(KafkaStrings.Get("Kafka/DescribeNeedsName")));
        End(tokens, "DESCRIBE " + what);
        return what == "TOPIC" ? new KafkaDescribeTopic(name) : new KafkaDescribeGroup(name);
    }

    private static KafkaCreateTopic ParseCreate(Tokenizer tokens)
    {
        if (!string.Equals(tokens.Next(), "TOPIC", StringComparison.OrdinalIgnoreCase))
        {
            throw new KafkaQLException(KafkaStrings.Format("Kafka/NeedsTopicKeyword", "CREATE"));
        }

        var topic = Unquote(tokens.Next() ?? throw new KafkaQLException(KafkaStrings.Format("Kafka/NeedsTopicName", "CREATE TOPIC")));
        var partitions = -1;
        short replication = -1;
        var config = new Dictionary<string, string>(StringComparer.Ordinal);
        while (tokens.Next()?.ToUpperInvariant() is { } keyword)
        {
            switch (keyword)
            {
                case "PARTITIONS" or "PARTITION":
                    partitions = Integer(tokens, keyword);
                    if (partitions < 1)
                    {
                        throw new KafkaQLException(KafkaStrings.Format("Kafka/AtLeastOne", "PARTITIONS"));
                    }

                    break;
                case "REPLICATION" or "REPLICATION_FACTOR" or "REPLICAS":
                    var factor = Integer(tokens, keyword);
                    replication = factor is >= 1 and <= short.MaxValue ? (short)factor : throw new KafkaQLException(KafkaStrings.Format("Kafka/AtLeastOne", "REPLICATION"));
                    break;
                case "CONFIG" or "WITH":
                    var setting = SplitAssignment(Required(tokens, keyword)) ?? throw new KafkaQLException(KafkaStrings.Format("Kafka/NeedsKeyValue", keyword));
                    config[setting.Key] = setting.Value;
                    break;
                default:
                    throw new KafkaQLException(KafkaStrings.Format("Kafka/Unexpected", keyword, "CREATE TOPIC"));
            }
        }

        return new KafkaCreateTopic(topic, partitions, replication, config);
    }

    /// <summary><c>DROP TOPIC</c>, and deliberately not <c>DROP TABLE</c>: a topic is not a table.</summary>
    private static KafkaDropTopic ParseDrop(Tokenizer tokens)
    {
        if (!string.Equals(tokens.Next(), "TOPIC", StringComparison.OrdinalIgnoreCase))
        {
            throw new KafkaQLException(KafkaStrings.Format("Kafka/NeedsTopicKeyword", "DROP"));
        }

        var topic = Unquote(tokens.Next() ?? throw new KafkaQLException(KafkaStrings.Format("Kafka/NeedsTopicName", "DROP TOPIC")));
        if (tokens.Next() is not null)
        {
            throw new KafkaQLException(KafkaStrings.Get("Kafka/DropTakesOne"));
        }

        return new KafkaDropTopic(topic);
    }

    /// <summary>Refuses anything after a complete statement, so an ignored word never reads as applied.</summary>
    private static void End(Tokenizer tokens, string statement)
    {
        if (tokens.Next() is { } extra)
        {
            throw new KafkaQLException(KafkaStrings.Format("Kafka/TakesNothingAfter", statement, extra));
        }
    }

    private static string Required(Tokenizer tokens, string keyword) => tokens.Next() ?? throw new KafkaQLException(KafkaStrings.Format("Kafka/NeedsValue", keyword));

    private static int Integer(Tokenizer tokens, string keyword)
    {
        var raw = Required(tokens, keyword);
        return int.TryParse(raw, NumberStyles.Integer, CultureInfo.InvariantCulture, out var value)
            ? value
            : throw new KafkaQLException(KafkaStrings.Format("Kafka/NeedsWholeNumber", keyword, raw));
    }

    private static long LongValue(Tokenizer tokens, string keyword)
    {
        var raw = Required(tokens, keyword);
        return long.TryParse(raw, NumberStyles.Integer, CultureInfo.InvariantCulture, out var value) && value >= 0
            ? value
            : throw new KafkaQLException(KafkaStrings.Format("Kafka/NeedsWholeNumber", keyword, raw));
    }

    /// <summary>Milliseconds since the epoch or an ISO 8601 instant, since someone reaching for a time has a clock reading.</summary>
    private static long Timestamp(Tokenizer tokens)
    {
        var raw = Unquote(Required(tokens, "TIME"));
        if (long.TryParse(raw, NumberStyles.Integer, CultureInfo.InvariantCulture, out var milliseconds))
        {
            return milliseconds;
        }

        return DateTimeOffset.TryParse(raw, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var instant)
            ? instant.ToUnixTimeMilliseconds()
            : throw new KafkaQLException(KafkaStrings.Format("Kafka/NotATimeHint", raw));
    }

    private static Dictionary<int, long> OffsetMap(string? token, string keyword)
    {
        var raw = token ?? throw new KafkaQLException(KafkaStrings.Format("Kafka/NeedsOffsetList", keyword));
        var body = raw.StartsWith('(') ? raw.Trim('(', ')') : raw;
        var map = new Dictionary<int, long>();
        foreach (var pair in body.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            var parts = pair.Split(':', StringSplitOptions.TrimEntries);
            if (parts.Length != 2
                || !int.TryParse(parts[0], NumberStyles.Integer, CultureInfo.InvariantCulture, out var partition)
                || !long.TryParse(parts[1], NumberStyles.Integer, CultureInfo.InvariantCulture, out var offset))
            {
                throw new KafkaQLException(KafkaStrings.Format("Kafka/NotOffsetPair", pair));
            }

            map[partition] = offset;
        }

        return map.Count > 0 ? map : throw new KafkaQLException(KafkaStrings.Format("Kafka/NeedsOffsetList", keyword));
    }

    private static List<int> PartitionList(Tokenizer tokens)
    {
        var raw = tokens.Next() ?? throw new KafkaQLException(KafkaStrings.Get("Kafka/PartitionNeedsNumber"));
        var body = raw.StartsWith('(') ? raw.Trim('(', ')') : raw;
        var values = new List<int>();
        foreach (var entry in body.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            // Dropping what does not parse would turn a typo into a silently narrower read.
            values.Add(int.TryParse(entry, NumberStyles.Integer, CultureInfo.InvariantCulture, out var value) && value >= 0
                ? value
                : throw new KafkaQLException(KafkaStrings.Format("Kafka/NotPartitionNumber", entry)));
        }

        // The tokenizer splits "0,1,2" outside parentheses, so the numbers that follow belong to the list too.
        while (!raw.StartsWith('(') && tokens.Peek() is { } next && int.TryParse(next, NumberStyles.Integer, CultureInfo.InvariantCulture, out var more))
        {
            tokens.Next();
            values.Add(more >= 0 ? more : throw new KafkaQLException(KafkaStrings.Format("Kafka/NotPartitionNumber", next)));
        }

        return values.Count > 0 ? values : throw new KafkaQLException(KafkaStrings.Get("Kafka/PartitionNeedsNumber"));
    }

    /// <summary>Splits <c>name=value</c> at the first <c>=</c> outside quotes; null when there is none.</summary>
    internal static KeyValuePair<string, string>? SplitAssignment(string token)
    {
        char? quote = null;
        for (var i = 0; i < token.Length; i++)
        {
            var c = token[i];
            if (quote is { } q)
            {
                if (c == '\\')
                {
                    i++;
                }
                else if (c == q)
                {
                    quote = null;
                }
            }
            else if (c is '"' or '\'' or '`')
            {
                quote = c;
            }
            else if (c == '=' && i > 0)
            {
                return new(Unquote(token[..i]), Unquote(token[(i + 1)..]));
            }
        }

        return null;
    }

    /// <summary>Splits on whitespace while keeping quoted strings and parenthesised lists whole.</summary>
    internal sealed class Tokenizer
    {
        private readonly List<string> _tokens;
        private int _index;

        private Tokenizer(List<string> tokens)
        {
            _tokens = tokens;
        }

        public IReadOnlyList<string> Tokens => _tokens;

        public static Tokenizer Tokenize(string input)
        {
            var tokens = new List<string>();
            var current = new StringBuilder();
            char? quote = null;
            var depth = 0;
            var escaped = false;
            foreach (var c in input)
            {
                if (escaped)
                {
                    current.Append(c);
                    escaped = false;
                    continue;
                }

                if (c == '\\' && quote is not null)
                {
                    escaped = true;
                    current.Append(c);
                    continue;
                }

                if (quote is { } active)
                {
                    current.Append(c);
                    if (c == active)
                    {
                        quote = null;
                    }

                    continue;
                }

                switch (c)
                {
                    case '"' or '\'' or '`':
                        quote = c;
                        current.Append(c);
                        break;
                    case '(':
                        depth++;
                        current.Append(c);
                        break;
                    case ')':
                        depth = Math.Max(0, depth - 1);
                        current.Append(c);
                        break;
                    case ' ' or '\t' or '\n' or '\r' or ',':
                        if (depth > 0)
                        {
                            current.Append(c);
                        }
                        else if (current.Length > 0)
                        {
                            tokens.Add(current.ToString());
                            current.Clear();
                        }

                        break;
                    case ';':
                        if (current.Length > 0)
                        {
                            tokens.Add(current.ToString());
                            current.Clear();
                        }

                        break;
                    default:
                        current.Append(c);
                        break;
                }
            }

            if (quote is not null)
            {
                throw new KafkaQLException(CoreStrings.Get("Driver/QuotedValueNotClosed"));
            }

            if (current.Length > 0)
            {
                tokens.Add(current.ToString());
            }

            return new Tokenizer(tokens);
        }

        public string? Next() => _index < _tokens.Count ? _tokens[_index++] : null;

        public string? Peek() => _index < _tokens.Count ? _tokens[_index] : null;
    }
}
