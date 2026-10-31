using System.Collections.Frozen;
using System.Collections.Immutable;

namespace TablePro.Core.Sql;

/// <summary>redis-cli commands, one per line. Safe Mode reads each command's verb.</summary>
public sealed class RedisDialect : CommandDialect
{
    public static readonly RedisDialect Instance = new();

    private static readonly FrozenSet<string> Reads = Verbs(
        "GET", "MGET", "GETRANGE", "STRLEN", "EXISTS", "TYPE", "TTL", "PTTL", "EXPIRETIME", "KEYS", "SCAN", "RANDOMKEY", "DBSIZE",
        "HGET", "HMGET", "HGETALL", "HKEYS", "HVALS", "HLEN", "HEXISTS", "HSCAN", "HSTRLEN", "HRANDFIELD",
        "LRANGE", "LINDEX", "LLEN", "LPOS", "SMEMBERS", "SISMEMBER", "SMISMEMBER", "SCARD", "SSCAN", "SRANDMEMBER", "SINTER", "SUNION", "SDIFF",
        "ZRANGE", "ZRANGEBYSCORE", "ZRANGEBYLEX", "ZREVRANGE", "ZREVRANGEBYSCORE", "ZSCORE", "ZMSCORE", "ZCARD", "ZCOUNT", "ZRANK", "ZREVRANK", "ZSCAN", "ZLEXCOUNT",
        "XRANGE", "XREVRANGE", "XLEN", "XREAD", "XINFO", "XPENDING", "PFCOUNT", "GETBIT", "BITCOUNT", "BITPOS", "GEOPOS", "GEODIST", "GEOSEARCH", "GEOHASH",
        "OBJECT", "MEMORY", "DUMP", "INFO", "PING", "ECHO", "TIME", "LASTSAVE", "ROLE", "CLIENT", "CONFIG", "SLOWLOG", "COMMAND", "LOLWUT",
        "JSON.GET", "JSON.MGET", "JSON.TYPE", "JSON.STRLEN", "JSON.ARRLEN", "JSON.OBJKEYS", "FT.SEARCH", "FT.INFO", "FT._LIST", "TS.GET", "TS.RANGE");

    private static readonly FrozenSet<string> Writes = Verbs(
        "SET", "SETNX", "SETEX", "PSETEX", "MSET", "MSETNX", "GETSET", "GETDEL", "GETEX", "APPEND", "SETRANGE", "INCR", "INCRBY", "INCRBYFLOAT", "DECR", "DECRBY",
        "DEL", "UNLINK", "EXPIRE", "PEXPIRE", "EXPIREAT", "PEXPIREAT", "PERSIST", "RENAME", "RENAMENX", "COPY", "MOVE", "RESTORE", "TOUCH",
        "HSET", "HSETNX", "HMSET", "HDEL", "HINCRBY", "HINCRBYFLOAT", "LPUSH", "RPUSH", "LPUSHX", "RPUSHX", "LPOP", "RPOP", "LSET", "LREM", "LTRIM", "LINSERT", "LMOVE", "RPOPLPUSH",
        "SADD", "SREM", "SPOP", "SMOVE", "SINTERSTORE", "SUNIONSTORE", "SDIFFSTORE", "ZADD", "ZREM", "ZINCRBY", "ZPOPMIN", "ZPOPMAX", "ZREMRANGEBYSCORE", "ZREMRANGEBYRANK", "ZREMRANGEBYLEX",
        "XADD", "XDEL", "XTRIM", "XGROUP", "XACK", "XCLAIM", "PFADD", "PFMERGE", "SETBIT", "BITOP", "GEOADD", "PUBLISH", "EVAL", "EVALSHA", "FCALL",
        "JSON.SET", "JSON.DEL", "JSON.ARRAPPEND", "JSON.NUMINCRBY", "TS.ADD", "TS.CREATE", "MULTI", "EXEC");

    private static readonly FrozenSet<string> Structure = Verbs("FLUSHDB", "FLUSHALL", "FT.CREATE", "FT.DROPINDEX", "SAVE", "BGSAVE", "BGREWRITEAOF", "SHUTDOWN", "DEBUG", "SWAPDB");

    private static readonly FrozenSet<string> Session = Verbs("SELECT", "AUTH", "HELLO", "RESET", "QUIT", "DISCARD", "WATCH", "UNWATCH");

    private RedisDialect()
    {
    }

    public override string Name => "Redis";

    protected override FrozenSet<string> ReadVerbs => Reads;

    protected override FrozenSet<string> WriteVerbs => Writes;

    protected override FrozenSet<string> StructureVerbs => Structure;

    protected override FrozenSet<string> SessionVerbs => Session;

    public override StatementKind Classify(string statement)
    {
        var words = CommandWords.Read(statement, 2);

        // CONFIG SET and CLIENT KILL change the server, while CONFIG GET and CLIENT LIST only read it.
        if (words.Count == 2 && words[0].ToUpperInvariant() is "CONFIG" or "CLIENT" or "SCRIPT" or "FUNCTION" or "ACL")
        {
            return words[1].ToUpperInvariant() is "GET" or "LIST" or "INFO" or "GETNAME" or "ID" or "EXISTS" or "WHOAMI" or "USERS" or "CAT"
                ? StatementKind.Read
                : StatementKind.Write;
        }

        return base.Classify(statement);
    }
}

/// <summary>etcdctl-style commands over etcd's key space.</summary>
public sealed class EtcdDialect : CommandDialect
{
    public static readonly EtcdDialect Instance = new();

    private EtcdDialect()
    {
    }

    public override string Name => "etcd";

    protected override FrozenSet<string> ReadVerbs { get; } = Verbs("get", "watch", "lease timetolive", "lease list", "member list", "endpoint status", "endpoint health", "alarm list", "user list", "role list");

    protected override FrozenSet<string> WriteVerbs { get; } = Verbs("put", "del", "txn", "compaction", "lease grant", "lease revoke", "lease keep-alive", "lock", "elect");

    protected override FrozenSet<string> StructureVerbs { get; } = Verbs("defrag", "snapshot save", "member add", "member remove", "user add", "user delete", "role add", "role delete", "auth enable", "auth disable");

    protected override int VerbWords(string firstWord) =>
        firstWord.ToLowerInvariant() is "lease" or "member" or "endpoint" or "alarm" or "user" or "role" or "snapshot" or "auth" ? 2 : 1;
}

/// <summary>KafkaQL, the macOS app's command language for topics and consumer groups.</summary>
public sealed class KafkaDialect : CommandDialect
{
    public static readonly KafkaDialect Instance = new();

    private KafkaDialect()
    {
    }

    public override string Name => "KafkaQL";

    public override string LineComment => "--";

    protected override FrozenSet<string> ReadVerbs { get; } = Verbs("SHOW", "DESCRIBE", "DESC", "SELECT", "CONSUME", "TAIL");

    protected override FrozenSet<string> WriteVerbs { get; } = Verbs("PRODUCE");

    protected override FrozenSet<string> StructureVerbs { get; } = Verbs("CREATE", "DROP", "ALTER");

    public override IEnumerable<string> CompletionKeywords =>
        base.CompletionKeywords.Concat(["TOPICS", "TOPIC", "GROUPS", "GROUP", "BROKERS", "CLUSTER", "FROM", "PARTITION", "OFFSET", "OLDEST", "NEWEST", "LIMIT", "KEY", "VALUE", "HEADER", "TIME", "SKIP", "ANCHOR"]);

    public override bool IsKeyword(ReadOnlySpan<char> word) => base.IsKeyword(word) || CompletionKeywords.Contains(word.ToString(), StringComparer.OrdinalIgnoreCase);
}

/// <summary>
/// mongosh statements: <c>db.users.find({...}).limit(5)</c>, <c>use shop</c>, <c>show collections</c>. A statement ends
/// at <c>;</c> or at a line break outside brackets, unless the next line continues a method chain with a dot.
/// </summary>
public sealed class MongoDialect : SqlDialect
{
    public static readonly MongoDialect Instance = new();

    private static readonly FrozenSet<string> ReadMethods = FrozenSet.Create(StringComparer.Ordinal,
        ["find", "findOne", "aggregate", "countDocuments", "estimatedDocumentCount", "count", "distinct", "getIndexes", "stats", "explain",
         "getCollectionNames", "getCollectionInfos", "listCollections", "getName", "watch", "dataSize", "totalSize", "storageSize", "isCapped", "hostInfo", "serverStatus", "version", "currentOp"]);

    private static readonly FrozenSet<string> WriteMethods = FrozenSet.Create(StringComparer.Ordinal,
        ["insertOne", "insertMany", "insert", "updateOne", "updateMany", "update", "replaceOne", "deleteOne", "deleteMany", "remove",
         "findOneAndUpdate", "findOneAndReplace", "findOneAndDelete", "findAndModify", "bulkWrite", "save", "killOp"]);

    private static readonly FrozenSet<string> StructureMethods = FrozenSet.Create(StringComparer.Ordinal,
        ["createCollection", "createView", "drop", "dropDatabase", "createIndex", "createIndexes", "dropIndex", "dropIndexes", "renameCollection",
         "runCommand", "adminCommand", "createUser", "dropUser", "grantRolesToUser", "revokeRolesFromUser"]);

    private MongoDialect()
    {
    }

    public override string Name => "MongoDB";

    public override bool IsSql => false;

    public override string LineComment => "//";

    public override SqlLexerFeatures LexerFeatures =>
        SqlLexerFeatures.DoubleQuotedStrings | SqlLexerFeatures.BackslashEscapes | SqlLexerFeatures.DoubleSlashComments | SqlLexerFeatures.BacktickIdentifiers;

    public override IReadOnlyList<string> Explain(string statement) =>
        statement.TrimEnd().TrimEnd(';').EndsWith(')') ? [statement.TrimEnd().TrimEnd(';') + ".explain(\"executionStats\")"] : [];

    public override string StringLiteral(string value) =>
        string.Concat("\"", value.Replace("\\", "\\\\", StringComparison.Ordinal).Replace("\"", "\\\"", StringComparison.Ordinal), "\"");

    public override string ParameterName(int index) => string.Create(System.Globalization.CultureInfo.InvariantCulture, $"${index + 1}");

    public override IEnumerable<string> CompletionKeywords =>
        ReadMethods.Concat(WriteMethods).Concat(StructureMethods).Concat(["db", "use", "show", "dbs", "collections", "getSiblingDB", "getCollection", "limit", "skip", "sort", "project", "toArray", "ObjectId", "ISODate", "NumberLong", "NumberDecimal", "UUID"])
            .Order(StringComparer.Ordinal);

    public override bool IsKeyword(ReadOnlySpan<char> word)
    {
        var text = word.ToString();
        return ReadMethods.Contains(text) || WriteMethods.Contains(text) || StructureMethods.Contains(text) || text is "db" or "use" or "show";
    }

    public override ImmutableArray<SqlStatement> Split(string text)
    {
        var builder = ImmutableArray.CreateBuilder<SqlStatement>();
        var span = text.AsSpan();
        var lexer = new SqlLexer(span, LexerFeatures);
        var tokens = new List<SqlToken>();
        while (lexer.TryRead(out var token))
        {
            tokens.Add(token);
        }

        var depth = 0;
        var start = -1;
        var end = -1;
        for (var i = 0; i < tokens.Count; i++)
        {
            var token = tokens[i];
            if (token.Kind is SqlTokenKind.LineComment or SqlTokenKind.BlockComment)
            {
                continue;
            }

            if (token.Kind == SqlTokenKind.Whitespace)
            {
                if (start >= 0 && depth == 0 && token.Slice(span).Contains('\n') && !NextContinues(tokens, i, span))
                {
                    Emit(text, start, end, builder);
                    start = -1;
                }

                continue;
            }

            if (token.Kind == SqlTokenKind.Semicolon && depth == 0)
            {
                Emit(text, start, end, builder);
                start = -1;
                continue;
            }

            var raw = token.Slice(span);
            if (token.Kind == SqlTokenKind.OpenParen || (token.Kind == SqlTokenKind.Operator && (raw.Contains('{') || raw.Contains('['))))
            {
                depth += Count(raw, '(') + Count(raw, '{') + Count(raw, '[');
            }

            if (token.Kind == SqlTokenKind.CloseParen || (token.Kind == SqlTokenKind.Operator && (raw.Contains('}') || raw.Contains(']'))))
            {
                depth = Math.Max(0, depth - Count(raw, ')') - Count(raw, '}') - Count(raw, ']'));
            }

            if (start < 0)
            {
                start = token.Start;
            }

            end = token.End;
        }

        Emit(text, start, end, builder);
        return builder.ToImmutable();
    }

    public override StatementKind Classify(string statement)
    {
        var trimmed = statement.TrimStart();
        if (trimmed.StartsWith("use ", StringComparison.Ordinal))
        {
            return StatementKind.Session;
        }

        if (trimmed.StartsWith("show ", StringComparison.Ordinal))
        {
            return StatementKind.Read;
        }

        var span = statement.AsSpan();
        var lexer = new SqlLexer(span, LexerFeatures);
        StatementKind? result = null;
        var afterDot = false;
        while (lexer.TryRead(out var token))
        {
            if (token.Kind == SqlTokenKind.Dot)
            {
                afterDot = true;
                continue;
            }

            if (token.Kind == SqlTokenKind.Word && afterDot)
            {
                var name = token.Slice(span).ToString();
                StatementKind? kind = WriteMethods.Contains(name) ? StatementKind.Write
                    : StructureMethods.Contains(name) ? StatementKind.Ddl
                    : ReadMethods.Contains(name) ? StatementKind.Read
                    : null;

                // The strongest effect wins: a write anywhere in the chain makes the statement a write.
                if (kind is { } k && (result is null || Rank(k) > Rank(result.Value)))
                {
                    result = k;
                }
            }

            if (token.Kind is not (SqlTokenKind.Whitespace or SqlTokenKind.LineComment or SqlTokenKind.BlockComment))
            {
                afterDot = false;
            }
        }

        // An aggregation that ends in $out or $merge writes its output to a collection.
        if (result == StatementKind.Read && (statement.Contains("$out", StringComparison.Ordinal) || statement.Contains("$merge", StringComparison.Ordinal)))
        {
            return StatementKind.Write;
        }

        return result ?? StatementKind.Unknown;
    }

    private static int Rank(StatementKind kind) => kind switch
    {
        StatementKind.Read => 0,
        StatementKind.Write => 1,
        StatementKind.Ddl => 2,
        _ => 3,
    };

    private static int Count(ReadOnlySpan<char> text, char c)
    {
        var count = 0;
        foreach (var ch in text)
        {
            if (ch == c)
            {
                count++;
            }
        }

        return count;
    }

    private static bool NextContinues(List<SqlToken> tokens, int index, ReadOnlySpan<char> text)
    {
        for (var j = index + 1; j < tokens.Count; j++)
        {
            if (tokens[j].IsTrivia)
            {
                continue;
            }

            return tokens[j].Kind == SqlTokenKind.Dot || (tokens[j].Kind == SqlTokenKind.Number && text[tokens[j].Start] == '.');
        }

        return false;
    }

    private static void Emit(string text, int start, int end, ImmutableArray<SqlStatement>.Builder builder)
    {
        if (start >= 0 && end > start)
        {
            builder.Add(new SqlStatement(start, end - start, text[start..end]));
        }
    }
}

/// <summary>
/// A REST request console, as Kibana's Dev Tools reads it: a line <c>GET /index/_search</c> and the JSON body below it,
/// up to the next request line. Elasticsearch and Typesense speak it.
/// </summary>
public abstract class RequestDialect : SqlDialect
{
    private static readonly string[] Methods = ["GET", "POST", "PUT", "DELETE", "HEAD", "PATCH"];

    public override bool IsSql => false;

    public override string LineComment => "#";

    public override SqlLexerFeatures LexerFeatures => SqlLexerFeatures.DoubleQuotedStrings | SqlLexerFeatures.BackslashEscapes | SqlLexerFeatures.HashComments | SqlLexerFeatures.DoubleSlashComments;

    public override IReadOnlyList<string> Explain(string statement) => [];

    public override IEnumerable<string> CompletionKeywords => Methods.Concat(PathWords);

    protected abstract IEnumerable<string> PathWords { get; }

    public override bool IsKeyword(ReadOnlySpan<char> word)
    {
        foreach (var method in Methods)
        {
            if (word.Equals(method, StringComparison.Ordinal))
            {
                return true;
            }
        }

        return false;
    }

    public override ImmutableArray<SqlStatement> Split(string text)
    {
        var builder = ImmutableArray.CreateBuilder<SqlStatement>();
        var start = -1;
        var end = 0;
        var lineStart = 0;
        while (lineStart <= text.Length)
        {
            var newline = text.IndexOf('\n', lineStart);
            var lineEnd = newline < 0 ? text.Length : newline;
            var line = text.AsSpan(lineStart, lineEnd - lineStart).TrimEnd('\r');
            var trimmed = line.Trim();
            if (IsRequestLine(trimmed))
            {
                if (start >= 0)
                {
                    builder.Add(new SqlStatement(start, end - start, text[start..end]));
                }

                start = lineStart + (line.Length - line.TrimStart().Length);
            }

            if (start >= 0 && !trimmed.IsEmpty && !trimmed.StartsWith(LineComment, StringComparison.Ordinal))
            {
                end = lineStart + line.TrimEnd().Length;
            }

            if (newline < 0)
            {
                break;
            }

            lineStart = newline + 1;
        }

        if (start >= 0 && end > start)
        {
            builder.Add(new SqlStatement(start, end - start, text[start..end]));
        }

        return builder.ToImmutable();
    }

    public override StatementKind Classify(string statement)
    {
        var (method, path) = ParseRequestLine(statement);
        return method switch
        {
            null => StatementKind.Unknown,
            "GET" or "HEAD" => StatementKind.Read,
            _ => ClassifyPath(method, path),
        };
    }

    /// <summary>The method and path of a request's first line.</summary>
    public static (string? Method, string Path) ParseRequestLine(string statement)
    {
        var firstLine = statement.AsSpan().TrimStart();
        var newline = firstLine.IndexOf('\n');
        if (newline >= 0)
        {
            firstLine = firstLine[..newline];
        }

        var words = CommandWords.Read(firstLine.Trim().ToString(), 2);
        return words.Count == 0 || !Methods.Contains(words[0].ToUpperInvariant())
            ? (null, string.Empty)
            : (words[0].ToUpperInvariant(), words.Count > 1 ? words[1] : "/");
    }

    /// <summary>POST, PUT, PATCH or DELETE on a path; a POST that only searches is a read.</summary>
    protected abstract StatementKind ClassifyPath(string method, string path);

    private static bool IsRequestLine(ReadOnlySpan<char> line)
    {
        foreach (var method in Methods)
        {
            if (line.StartsWith(method, StringComparison.OrdinalIgnoreCase) && line.Length > method.Length && char.IsWhiteSpace(line[method.Length]))
            {
                return true;
            }
        }

        return false;
    }
}

public sealed class ElasticsearchDialect : RequestDialect
{
    public static readonly ElasticsearchDialect Instance = new();

    private ElasticsearchDialect()
    {
    }

    public override string Name => "Query DSL";

    protected override IEnumerable<string> PathWords => ["_search", "_count", "_doc", "_bulk", "_mapping", "_settings", "_cat/indices", "_update", "_delete_by_query", "_update_by_query", "_msearch", "_sql", "query", "match", "term", "bool", "must", "filter", "aggs", "size", "sort"];

    protected override StatementKind ClassifyPath(string method, string path)
    {
        var lower = path.ToLowerInvariant();
        if (method == "POST" && (lower.Contains("_search", StringComparison.Ordinal) || lower.Contains("_count", StringComparison.Ordinal)
            || lower.Contains("_msearch", StringComparison.Ordinal) || lower.Contains("_sql", StringComparison.Ordinal) || lower.Contains("_validate", StringComparison.Ordinal)))
        {
            return StatementKind.Read;
        }

        // A PUT or DELETE on a bare index path creates or removes the whole index.
        var segments = lower.Trim('/').Split('/', StringSplitOptions.RemoveEmptyEntries);
        if (method is "PUT" or "DELETE" && segments.Length == 1 && !segments[0].StartsWith('_'))
        {
            return StatementKind.Ddl;
        }

        return lower.Contains("_mapping", StringComparison.Ordinal) || lower.Contains("_settings", StringComparison.Ordinal) ? StatementKind.Ddl : StatementKind.Write;
    }
}

public sealed class TypesenseDialect : RequestDialect
{
    public static readonly TypesenseDialect Instance = new();

    private TypesenseDialect()
    {
    }

    public override string Name => "Typesense API";

    protected override IEnumerable<string> PathWords => ["/collections", "/documents", "/documents/search", "/multi_search", "/keys", "/aliases", "/synonyms", "/metrics.json", "/health"];

    protected override StatementKind ClassifyPath(string method, string path)
    {
        var lower = path.ToLowerInvariant();
        if (method == "POST" && lower.Contains("search", StringComparison.Ordinal))
        {
            return StatementKind.Read;
        }

        var segments = lower.Trim('/').Split('/', StringSplitOptions.RemoveEmptyEntries);
        return segments is ["collections"] or ["collections", _] && method is "POST" or "DELETE" or "PATCH" ? StatementKind.Ddl : StatementKind.Write;
    }
}

/// <summary>Weaviate's GraphQL: each top-level <c>{ ... }</c> operation is a statement; only a mutation writes.</summary>
public sealed class GraphQlDialect : SqlDialect
{
    public static readonly GraphQlDialect Instance = new();

    private GraphQlDialect()
    {
    }

    public override string Name => "GraphQL";

    public override bool IsSql => false;

    public override string LineComment => "#";

    public override SqlLexerFeatures LexerFeatures => SqlLexerFeatures.DoubleQuotedStrings | SqlLexerFeatures.BackslashEscapes | SqlLexerFeatures.HashComments;

    public override IReadOnlyList<string> Explain(string statement) => [];

    public override IEnumerable<string> CompletionKeywords => ["query", "mutation", "Get", "Aggregate", "Explore", "where", "limit", "offset", "nearText", "nearVector", "hybrid", "bm25", "_additional", "id", "distance", "certainty"];

    public override bool IsKeyword(ReadOnlySpan<char> word) => word is "query" or "mutation" or "fragment" or "Get" or "Aggregate" or "Explore";

    public override ImmutableArray<SqlStatement> Split(string text)
    {
        var builder = ImmutableArray.CreateBuilder<SqlStatement>();
        var span = text.AsSpan();
        var lexer = new SqlLexer(span, LexerFeatures);
        var depth = 0;
        var start = -1;
        while (lexer.TryRead(out var token))
        {
            if (token.IsTrivia)
            {
                continue;
            }

            if (start < 0)
            {
                start = token.Start;
            }

            var raw = token.Slice(span);
            foreach (var c in raw)
            {
                if (token.Kind is SqlTokenKind.String or SqlTokenKind.QuotedIdentifier)
                {
                    break;
                }

                if (c == '{')
                {
                    depth++;
                }
                else if (c == '}' && --depth == 0)
                {
                    builder.Add(new SqlStatement(start, token.End - start, text[start..token.End]));
                    start = -1;
                    break;
                }
            }
        }

        if (start >= 0)
        {
            builder.Add(new SqlStatement(start, text.Length - start, text[start..]));
        }

        return builder.ToImmutable();
    }

    public override StatementKind Classify(string statement) =>
        statement.TrimStart().StartsWith("mutation", StringComparison.Ordinal) ? StatementKind.Write : StatementKind.Read;
}
