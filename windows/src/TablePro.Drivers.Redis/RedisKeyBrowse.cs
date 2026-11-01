using System.Buffers;
using System.Globalization;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using TablePro.Core.Browse;
using TablePro.Core.Editing;
using TablePro.Core.Localization;
using TablePro.Core.Results;
using TablePro.Core.Schema;
using TablePro.Drivers.Redis.Localization;

namespace TablePro.Drivers.Redis;

/// <summary>
/// What a key listing asks the server for, a SCAN <c>MATCH</c> glob and a <c>TYPE</c>, and the filter rules SCAN
/// cannot express, which are matched against each page after it is read.
/// </summary>
internal sealed record RedisKeyScope(string? Pattern, string? Type, BrowseFilter Remaining)
{
    /// <summary>Whether every rule went to the server, so a count of what SCAN finds is the count of what the grid lists.</summary>
    public bool IsServerSide => Remaining.IsEmpty;
}

/// <summary>One row's writes on the key listing, kept apart so a cluster can run each key's in its own slot.</summary>
internal sealed record RedisKeyWrite(string Key, RedisWritePlan Plan);

/// <summary>
/// A logical database as the macOS app shows it: one table with a row per key, its type, time to live, length and a
/// preview of its value. The rows come from SCAN, so the listing pages through any number of keys; the key and type
/// filters are sent to the server, and the TTL and a string's value are edited in place.
/// </summary>
internal static class RedisKeyBrowse
{
    public const string Key = "Key";
    public const string Type = "Type";
    public const string Ttl = "TTL";
    public const string Length = "Length";
    public const string Value = "Value";

    /// <summary>How much of a collection the value preview reads, as macOS does.</summary>
    public const int CollectionPreviewLimit = 100;

    public const int StreamPreviewLimit = 5;

    /// <summary>The types the type filter offers, by the names TYPE and SCAN TYPE use.</summary>
    public static readonly IReadOnlyList<string> Types = ["string", "hash", "list", "set", "zset", "stream", "ReJSON-RL"];

    private static readonly HashSet<string> InsertableTypes = new(StringComparer.OrdinalIgnoreCase) { "string", "hash", "list", "set", "zset" };

    private static readonly JsonWriterOptions JsonOptions = new() { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    public static readonly IReadOnlyList<ResultColumn> Columns =
    [
        new(Key, "string", typeof(string)),
        new(Type, "string", typeof(string)),
        new(Ttl, "integer", typeof(long)),
        new(Length, "integer", typeof(long)),
        new(Value, "string", typeof(string)),
    ];

    public static IReadOnlyList<ColumnInfo> StructureColumns() =>
    [
        new(Key, "string", IsNullable: false, DefaultValue: null, IsPrimaryKey: true, IsIdentity: false, Ordinal: 1, Comment: RedisStrings.Get("Redis/KeyNameComment")),
        new(Type, "string", IsNullable: true, DefaultValue: "string", IsPrimaryKey: false, IsIdentity: false, Ordinal: 2, Comment: RedisStrings.Get("Redis/TypeComment")),
        new(Ttl, "integer", IsNullable: true, DefaultValue: "-1", IsPrimaryKey: false, IsIdentity: false, Ordinal: 3, Comment: RedisStrings.Get("Redis/TtlComment")),
        new(Length, "integer", IsNullable: true, DefaultValue: null, IsPrimaryKey: false, IsIdentity: true, Ordinal: 4, Comment: RedisStrings.Get("Redis/LengthComment")),
        new(Value, "string", IsNullable: true, DefaultValue: null, IsPrimaryKey: false, IsIdentity: false, Ordinal: 5, Comment: RedisStrings.Get("Redis/ValueComment")),
    ];

    /// <summary>
    /// The listing's table name for a database. It has no schema, which tells it apart from a key of the same name:
    /// keys always carry their database as the schema.
    /// </summary>
    public static ObjectName TableName(int database) => new(null, RedisConnectionOptions.SchemaName(database));

    public static bool IsKeyTable(ObjectName table, out int database)
    {
        database = 0;
        return table.Schema is null
            && RedisConnectionOptions.TryParseDatabaseIndex(table.Name, out database)
            && table.Name == RedisConnectionOptions.SchemaName(database);
    }

    /// <summary>
    /// Splits the filter strip into what SCAN takes and what it does not. SCAN holds one pattern and one type and both
    /// must match, so only rules joined by AND are sent, at most one of each. A key rule of <c>=</c> is a glob as
    /// redis-cli's MATCH reads it, the way the macOS key pattern bar takes one; the text operators match literally.
    /// </summary>
    public static RedisKeyScope Scope(BrowseFilter filter)
    {
        if (!string.IsNullOrWhiteSpace(filter.RawWhere))
        {
            throw new NotSupportedException(RedisStrings.Get("Redis/NoWhereKeys"));
        }

        var rules = filter.Rules.Where(r => r.Enabled).ToList();
        string? pattern = null;
        string? type = null;
        if (filter.MatchAll || rules.Count == 1)
        {
            var keyRules = rules.Where(r => IsColumn(r, Key) && Glob(r) is not null).ToArray();
            if (keyRules.Length == 1)
            {
                pattern = Glob(keyRules[0]);
                rules.Remove(keyRules[0]);
            }

            var typeRules = rules.Where(r => IsColumn(r, Type) && r.Operator == FilterOperator.Equals && !string.IsNullOrWhiteSpace(r.Value)).ToArray();
            if (typeRules.Length == 1)
            {
                type = ScanTypeName(typeRules[0].Value!);
                rules.Remove(typeRules[0]);
            }
        }

        return new RedisKeyScope(pattern, type, filter with { Rules = rules });
    }

    /// <summary>The name SCAN TYPE takes: TYPE reports a ReJSON document as <c>ReJSON-RL</c>, which "json" stands for.</summary>
    public static string ScanTypeName(string type)
    {
        var trimmed = type.Trim();
        return trimmed.ToLowerInvariant() switch
        {
            "json" or "rejson" or "rejson-rl" => "ReJSON-RL",
            "sortedset" or "sorted set" => "zset",
            _ => trimmed.ToLowerInvariant(),
        };
    }

    /// <summary>SCAN learned its TYPE option in Redis 6.0; every Valkey release has it.</summary>
    public static bool SupportsScanType(string serverVersion)
    {
        if (serverVersion.StartsWith("Valkey", StringComparison.OrdinalIgnoreCase))
        {
            return true;
        }

        var major = serverVersion.Split('.', 2)[0];
        return !int.TryParse(major, NumberStyles.None, CultureInfo.InvariantCulture, out var number) || number >= 6;
    }

    /// <summary>Escapes the characters SCAN MATCH reads as a pattern, so text is matched as itself.</summary>
    public static string EscapeGlob(string text)
    {
        var builder = new StringBuilder(text.Length + 4);
        foreach (var c in text)
        {
            if (c is '*' or '?' or '[' or ']' or '\\')
            {
                builder.Append('\\');
            }

            builder.Append(c);
        }

        return builder.ToString();
    }

    public static RedisCommand? LengthCommand(RedisKeyType type, string key) => type switch
    {
        RedisKeyType.String => new RedisCommand("STRLEN", key),
        _ when RedisKeyTypes.LengthCommand(type) is { } verb => new RedisCommand(verb, key),
        _ => null,
    };

    /// <summary>
    /// The read that fills the Value cell. A string reads whole, since its cell is what an edit writes back; a
    /// collection reads its first elements only, so a key of a million members costs the same as a small one.
    /// </summary>
    public static RedisCommand? PreviewCommand(RedisKeyType type, string key)
    {
        var count = CollectionPreviewLimit.ToString(CultureInfo.InvariantCulture);
        var last = (CollectionPreviewLimit - 1).ToString(CultureInfo.InvariantCulture);
        return type switch
        {
            RedisKeyType.String => new RedisCommand("GET", key),
            RedisKeyType.Hash => new RedisCommand("HSCAN", key, "0", "COUNT", count),
            RedisKeyType.List => new RedisCommand("LRANGE", key, "0", last),
            RedisKeyType.Set => new RedisCommand("SSCAN", key, "0", "COUNT", count),
            RedisKeyType.SortedSet => new RedisCommand("ZRANGE", key, "0", last, "WITHSCORES"),
            RedisKeyType.Stream => new RedisCommand("XREVRANGE", key, "+", "-", "COUNT", StreamPreviewLimit.ToString(CultureInfo.InvariantCulture)),
            RedisKeyType.Json => new RedisCommand("JSON.GET", key),
            _ => null,
        };
    }

    /// <summary>The Value cell from the preview read: a string as itself, a collection as compact JSON.</summary>
    public static string? Preview(RedisKeyType type, RedisReply? reply)
    {
        if (reply is null || reply.IsNull || reply.Kind == RedisReplyKind.Error)
        {
            return null;
        }

        return type switch
        {
            RedisKeyType.String or RedisKeyType.Json => reply.IsAggregate ? RedisJson.Write(reply) : reply.Text,
            RedisKeyType.Hash => WriteJson(writer => WriteObject(writer, ScanItems(reply), sorted: true)),
            RedisKeyType.List => WriteJson(writer => WriteArray(writer, reply.Items)),
            RedisKeyType.Set => WriteJson(writer => WriteArray(writer, ScanItems(reply))),
            RedisKeyType.SortedSet => WriteJson(writer => WritePairs(writer, Flatten(reply.Items))),
            RedisKeyType.Stream => WriteJson(writer => WriteStream(writer, reply.Items)),
            _ => null,
        };
    }

    /// <summary>A whole number from an integer reply, or null when the server would not say.</summary>
    public static long? Integer(RedisReply? reply) =>
        reply is { Kind: RedisReplyKind.Integer or RedisReplyKind.Text or RedisReplyKind.Status } && long.TryParse(reply.Text, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var value)
            ? value
            : null;

    public static object?[] Row(string key, string? typeName, long? ttl, long? length, string? value) => [key, typeName, ttl, length, value];

    /// <summary>
    /// A page with no requested order is ordered by key, so a database smaller than a page reads alphabetically. SCAN
    /// returns keys in hash order, so a larger one is ordered within each page.
    /// </summary>
    public static IReadOnlyList<SortColumn> PageOrder(IReadOnlyList<SortColumn> sort) => sort.Count > 0 ? sort : [new SortColumn(Key, false)];

    /// <summary>The keys whose value an edit writes, whose type the save reads first: only a string's value is its cell.</summary>
    public static IReadOnlyList<string> KeysWritingValue(IReadOnlyList<RowChange> changes) =>
        changes.OfType<RowUpdate>()
            .Where(u => u.Values.ContainsKey(Value))
            .Select(u => Text(Get(u.Key, Key)))
            .OfType<string>()
            .Distinct(StringComparer.Ordinal)
            .ToArray();

    /// <summary>
    /// The writes for the grid's edits, one entry per changed row. Each row is guarded: an edited or deleted key must
    /// still exist, and a new or renamed one must not, so a save never overwrites a key the grid did not show.
    /// </summary>
    /// <param name="changes">The grid's edits.</param>
    /// <param name="types">
    /// The current type of each key in <see cref="KeysWritingValue"/>. Null for the review sheet, which is drawn before
    /// the save reads them and shows a value edit as the <c>SET</c> a string takes.
    /// </param>
    public static IReadOnlyList<RedisKeyWrite> Plan(IReadOnlyList<RowChange> changes, IReadOnlyDictionary<string, RedisKeyType>? types)
    {
        var writes = new List<RedisKeyWrite>(changes.Count);
        foreach (var change in changes.OfType<RowUpdate>())
        {
            writes.Add(PlanUpdate(change, types));
        }

        foreach (var change in changes.OfType<RowInsert>())
        {
            writes.Add(PlanInsert(change));
        }

        foreach (var change in changes.OfType<RowDelete>())
        {
            var key = Text(Get(change.Key, Key)) ?? throw Unaddressable();
            writes.Add(new RedisKeyWrite(key, new RedisWritePlan([new RedisGuard(RedisGuardKind.KeyExists, key)], [new RedisCommand("DEL", key)])));
        }

        return writes;
    }

    private static RedisKeyWrite PlanUpdate(RowUpdate update, IReadOnlyDictionary<string, RedisKeyType>? types)
    {
        var key = Text(Get(update.Key, Key)) ?? throw Unaddressable();
        var guards = new List<RedisGuard> { new(RedisGuardKind.KeyExists, key) };
        var commands = new List<RedisCommand>();
        var target = key;
        if (update.Values.TryGetValue(Key, out var renamed))
        {
            var newKey = Text(renamed);
            if (string.IsNullOrEmpty(newKey))
            {
                throw new NotSupportedException(RedisStrings.Get("Redis/RenameEmpty"));
            }

            if (newKey != key)
            {
                guards.Add(new RedisGuard(RedisGuardKind.KeyMissing, newKey));
                commands.Add(new RedisCommand("RENAME", key, newKey));
                target = newKey;
            }
        }

        foreach (var (column, value) in update.Values)
        {
            switch (column)
            {
                case Key:
                    break;
                case Value:
                    var text = Text(value) ?? throw new NotSupportedException(RedisStrings.Get("Redis/CannotStoreNullValue"));
                    var type = types is null ? RedisKeyType.String : types.GetValueOrDefault(key, RedisKeyType.None);
                    if (type == RedisKeyType.None)
                    {
                        throw new InvalidOperationException(CoreStrings.Format("Driver/KeyNoLongerExists", key));
                    }

                    if (type != RedisKeyType.String)
                    {
                        throw new NotSupportedException(RedisStrings.Format("Redis/ValueInListNotEditable", TypeName(type)));
                    }

                    // KEEPTTL (Redis 6.0) so editing a value does not clear the key's expiry.
                    commands.Add(new RedisCommand("SET", target, text, "KEEPTTL"));
                    break;
                case Ttl:
                    commands.Add(TtlCommand(target, value));
                    break;
                default:
                    throw new NotSupportedException(CoreStrings.Format("Driver/CannotChangeFromGrid", column));
            }
        }

        // The rename runs first, so the value and expiry commands name the key as it is by then.
        commands.Sort((a, b) => Order(a).CompareTo(Order(b)));
        return new RedisKeyWrite(key, new RedisWritePlan(guards, commands));

        static int Order(RedisCommand command) => command.Verb switch
        {
            "RENAME" => 0,
            "SET" => 1,
            _ => 2,
        };
    }

    private static RedisKeyWrite PlanInsert(RowInsert insert)
    {
        var key = Text(Get(insert.Values, Key));
        if (string.IsNullOrEmpty(key))
        {
            throw new NotSupportedException(RedisStrings.Get("Redis/NewKeyNeedsName"));
        }

        var typeName = Text(Get(insert.Values, Type))?.Trim();
        typeName = string.IsNullOrEmpty(typeName) ? "string" : ScanTypeName(typeName);
        if (!InsertableTypes.Contains(typeName))
        {
            throw new NotSupportedException(RedisStrings.Format("Redis/TypeNotAddable", typeName));
        }

        var value = Text(Get(insert.Values, Value)) ?? string.Empty;
        var commands = new List<RedisCommand>();
        switch (typeName)
        {
            case "hash":
                if (HashFields(value) is { Count: > 0 } fields)
                {
                    commands.AddRange(fields.Select(f => new RedisCommand("HSET", key, f.Key, f.Value)));
                }
                else
                {
                    commands.Add(new RedisCommand("HSET", key, "value", value));
                }

                break;
            case "list":
                commands.Add(new RedisCommand("RPUSH", key, value));
                break;
            case "set":
                commands.Add(new RedisCommand("SADD", key, value));
                break;
            case "zset":
                commands.Add(new RedisCommand("ZADD", key, "0", value));
                break;
            default:
                commands.Add(new RedisCommand("SET", key, value));
                break;
        }

        if (insert.Values.TryGetValue(Ttl, out var ttl) && Text(ttl)?.Trim() is { Length: > 0 } ttlText && ttlText != "-1")
        {
            commands.Add(TtlCommand(key, ttl));
        }

        return new RedisKeyWrite(key, new RedisWritePlan([new RedisGuard(RedisGuardKind.KeyMissing, key)], commands));
    }

    /// <summary>EXPIRE for a number of seconds, PERSIST for -1 or an empty cell, as macOS writes a TTL edit.</summary>
    public static RedisCommand TtlCommand(string key, object? value)
    {
        var text = Text(value)?.Trim();
        if (string.IsNullOrEmpty(text) || text == "-1")
        {
            return new RedisCommand("PERSIST", key);
        }

        return long.TryParse(text, NumberStyles.None, CultureInfo.InvariantCulture, out var seconds) && seconds > 0
            ? new RedisCommand("EXPIRE", key, seconds.ToString(CultureInfo.InvariantCulture))
            : throw new NotSupportedException(RedisStrings.Get("Redis/TtlInvalid"));
    }

    /// <summary>A JSON object's members as hash fields, a string member as its text and any other as its JSON.</summary>
    private static List<KeyValuePair<string, string>>? HashFields(string value)
    {
        if (!value.TrimStart().StartsWith('{'))
        {
            return null;
        }

        try
        {
            using var document = JsonDocument.Parse(value);
            return document.RootElement.EnumerateObject()
                .Select(p => new KeyValuePair<string, string>(p.Name, p.Value.ValueKind == JsonValueKind.String ? p.Value.GetString()! : p.Value.GetRawText()))
                .OrderBy(p => p.Key, StringComparer.Ordinal)
                .ToList();
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private static string TypeName(RedisKeyType type) => type switch
    {
        RedisKeyType.SortedSet => "zset",
        RedisKeyType.Json => "ReJSON-RL",
        _ => type.ToString().ToLowerInvariant(),
    };

    private static NotSupportedException Unaddressable() => new(RedisStrings.Get("Redis/KeyNameNotText"));

    private static bool IsColumn(FilterRule rule, string column) => string.Equals(rule.Column, column, StringComparison.OrdinalIgnoreCase);

    private static string? Glob(FilterRule rule)
    {
        if (string.IsNullOrEmpty(rule.Value))
        {
            return null;
        }

        var value = rule.Value;
        return rule.Operator switch
        {
            FilterOperator.Equals => value,
            FilterOperator.StartsWith => EscapeGlob(value) + "*",
            FilterOperator.EndsWith => "*" + EscapeGlob(value),
            FilterOperator.Contains => "*" + EscapeGlob(value) + "*",
            _ => null,
        };
    }

    // HSCAN and SSCAN reply [cursor, [items]]; a bare list stands for the items when a test or proxy flattens it.
    private static IReadOnlyList<RedisReply> ScanItems(RedisReply reply) =>
        reply.Items.Count == 2 && reply.Items[1].IsAggregate ? reply.Items[1].Items : reply.Items;

    // RESP3 replies to WITHSCORES as [[member, score], ...] instead of a flat list.
    private static IReadOnlyList<RedisReply> Flatten(IReadOnlyList<RedisReply> items) =>
        items.Count > 0 && items.All(i => i.IsAggregate && i.Items.Count == 2) ? items.SelectMany(i => i.Items).ToArray() : items;

    private static string WriteJson(Action<Utf8JsonWriter> write)
    {
        var buffer = new ArrayBufferWriter<byte>();
        using (var writer = new Utf8JsonWriter(buffer, JsonOptions))
        {
            write(writer);
        }

        return Encoding.UTF8.GetString(buffer.WrittenSpan);
    }

    private static void WriteObject(Utf8JsonWriter writer, IReadOnlyList<RedisReply> flat, bool sorted)
    {
        var pairs = new List<(string Name, string? Value)>(flat.Count / 2);
        for (var i = 0; i + 1 < flat.Count; i += 2)
        {
            pairs.Add((flat[i].Text ?? string.Empty, RedisReplyShaper.CellText(flat[i + 1])));
        }

        if (sorted)
        {
            pairs.Sort((a, b) => string.CompareOrdinal(a.Name, b.Name));
        }

        writer.WriteStartObject();
        foreach (var (name, value) in pairs)
        {
            writer.WriteString(name, value);
        }

        writer.WriteEndObject();
    }

    private static void WriteArray(Utf8JsonWriter writer, IReadOnlyList<RedisReply> items)
    {
        writer.WriteStartArray();
        foreach (var item in items)
        {
            writer.WriteStringValue(RedisReplyShaper.CellText(item));
        }

        writer.WriteEndArray();
    }

    private static void WritePairs(Utf8JsonWriter writer, IReadOnlyList<RedisReply> flat)
    {
        writer.WriteStartArray();
        for (var i = 0; i + 1 < flat.Count; i += 2)
        {
            writer.WriteStartArray();
            writer.WriteStringValue(RedisReplyShaper.CellText(flat[i]));
            writer.WriteStringValue(RedisReplyShaper.CellText(flat[i + 1]));
            writer.WriteEndArray();
        }

        writer.WriteEndArray();
    }

    private static void WriteStream(Utf8JsonWriter writer, IReadOnlyList<RedisReply> entries)
    {
        writer.WriteStartArray();
        foreach (var entry in entries)
        {
            if (entry.Items.Count < 2)
            {
                continue;
            }

            writer.WriteStartArray();
            writer.WriteStringValue(entry.Items[0].Text);
            WriteObject(writer, entry.Items[1].Items, sorted: true);
            writer.WriteEndArray();
        }

        writer.WriteEndArray();
    }

    private static object? Get(IReadOnlyDictionary<string, object?> values, string column) =>
        values.TryGetValue(column, out var value) ? value : null;

    private static string? Text(object? value) => value switch
    {
        null => null,
        string s => s,
        IFormattable f => f.ToString(null, CultureInfo.InvariantCulture),
        _ => value.ToString(),
    };
}
