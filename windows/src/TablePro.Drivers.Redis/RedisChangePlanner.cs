using System.Globalization;
using System.Text.Json;
using TablePro.Core.Editing;

namespace TablePro.Drivers.Redis;

/// <summary>
/// Turns the grid's edits of one key into the commands that make them, with the guards that keep a save from
/// changing rows other than the ones the grid showed. What a type cannot express is refused before anything runs.
/// </summary>
internal static class RedisChangePlanner
{
    /// <summary>
    /// The current values a plan needs that the edits do not carry: a hash field or sorted set member renamed without
    /// a new value keeps its old one, which only the server knows.
    /// </summary>
    public static IReadOnlyList<string> RequiredLookups(RedisKeyType type, IReadOnlyList<RowChange> changes)
    {
        var (keyColumn, valueColumn) = type switch
        {
            RedisKeyType.Hash => (RedisKeyLayout.Field, RedisKeyLayout.Value),
            RedisKeyType.SortedSet => (RedisKeyLayout.Member, RedisKeyLayout.Score),
            _ => (null, null),
        };
        if (keyColumn is null || valueColumn is null)
        {
            return [];
        }

        var lookups = new List<string>();
        foreach (var update in changes.OfType<RowUpdate>())
        {
            var old = Text(Get(update.Key, keyColumn));
            if (old is not null && TryGet(update.Values, keyColumn, out var renamed) && Text(renamed) != old && !TryGet(update.Values, valueColumn, out _))
            {
                lookups.Add(old);
            }
        }

        return lookups;
    }

    /// <param name="type">The key's type as TYPE reports it now.</param>
    /// <param name="key">The key being edited.</param>
    /// <param name="changes">The grid's edits, in the order the edit buffer lists them.</param>
    /// <param name="current">The values <see cref="RequiredLookups"/> named, read from the server.</param>
    /// <param name="deletedMarker">The placeholder list deletes write before removing it; random unless a test fixes it.</param>
    public static RedisWritePlan Plan(
        RedisKeyType type,
        string key,
        IReadOnlyList<RowChange> changes,
        IReadOnlyDictionary<string, string?>? current = null,
        string? deletedMarker = null)
    {
        current ??= new Dictionary<string, string?>();
        var guards = new List<RedisGuard>();
        var commands = new List<RedisCommand>();
        switch (type)
        {
            case RedisKeyType.String:
                PlanString(key, changes, guards, commands);
                break;
            case RedisKeyType.Hash:
                PlanHash(key, changes, current, guards, commands);
                break;
            case RedisKeyType.List:
                PlanList(key, changes, deletedMarker ?? "__tablepro_deleted_" + Guid.NewGuid().ToString("N"), guards, commands);
                break;
            case RedisKeyType.Set:
                PlanSet(key, changes, guards, commands);
                break;
            case RedisKeyType.SortedSet:
                PlanSortedSet(key, changes, current, guards, commands);
                break;
            case RedisKeyType.Stream:
                PlanStream(key, changes, commands);
                break;
            case RedisKeyType.Json:
                PlanJson(key, changes, commands);
                break;
            case RedisKeyType.None:
                throw new InvalidOperationException($"The key '{key}' no longer exists, so nothing was saved.");
            default:
                throw new NotSupportedException($"The key '{key}' holds a type the grid cannot edit. Change it with a command in the query editor.");
        }

        return new RedisWritePlan(guards, commands);
    }

    private static void PlanString(string key, IReadOnlyList<RowChange> changes, List<RedisGuard> guards, List<RedisCommand> commands)
    {
        foreach (var change in changes)
        {
            switch (change)
            {
                case RowUpdate update:
                    if (!TryGet(update.Values, RedisKeyLayout.Value, out var value))
                    {
                        continue;
                    }

                    var text = Text(value) ?? throw NullValue();
                    if (Text(Get(update.Key, RedisKeyLayout.Value)) is { } old)
                    {
                        guards.Add(new RedisGuard(RedisGuardKind.StringEquals, key, Value: old));
                    }
                    else
                    {
                        guards.Add(new RedisGuard(RedisGuardKind.KeyExists, key));
                    }

                    // KEEPTTL (Redis 6.0) so editing a value does not clear the key's expiry.
                    commands.Add(new RedisCommand("SET", key, text, "KEEPTTL"));
                    break;
                case RowDelete:
                    guards.Add(new RedisGuard(RedisGuardKind.KeyExists, key));
                    commands.Add(new RedisCommand("DEL", key));
                    break;
                case RowInsert:
                    throw new NotSupportedException("A string key holds one value. Edit that value instead of adding a row.");
            }
        }
    }

    private static void PlanHash(string key, IReadOnlyList<RowChange> changes, IReadOnlyDictionary<string, string?> current, List<RedisGuard> guards, List<RedisCommand> commands)
    {
        foreach (var change in changes)
        {
            switch (change)
            {
                case RowUpdate update:
                {
                    var field = RequiredKey(update.Key, RedisKeyLayout.Field, "hash field");
                    var renamed = TryGet(update.Values, RedisKeyLayout.Field, out var newFieldValue) ? Text(newFieldValue) ?? throw NullValue() : field;
                    var hasValue = TryGet(update.Values, RedisKeyLayout.Value, out var newValue);
                    if (hasValue && Text(newValue) is null)
                    {
                        throw NullValue();
                    }

                    if (renamed != field)
                    {
                        string value;
                        if (hasValue)
                        {
                            value = Text(newValue)!;
                            guards.Add(new RedisGuard(RedisGuardKind.HashFieldExists, key, field));
                        }
                        else
                        {
                            value = current.TryGetValue(field, out var read) && read is not null
                                ? read
                                : throw new InvalidOperationException($"The hash field '{field}' no longer exists, so nothing was saved.");

                            // The value was read before the transaction; it must still be the same when it runs.
                            guards.Add(new RedisGuard(RedisGuardKind.HashFieldEquals, key, field, read));
                        }

                        guards.Add(new RedisGuard(RedisGuardKind.HashFieldMissing, key, renamed));
                        commands.Add(new RedisCommand("HDEL", key, field));
                        commands.Add(new RedisCommand("HSET", key, renamed, value));
                    }
                    else if (hasValue)
                    {
                        guards.Add(new RedisGuard(RedisGuardKind.HashFieldExists, key, field));
                        commands.Add(new RedisCommand("HSET", key, field, Text(newValue)!));
                    }

                    break;
                }

                case RowDelete delete:
                {
                    var field = RequiredKey(delete.Key, RedisKeyLayout.Field, "hash field");
                    guards.Add(new RedisGuard(RedisGuardKind.HashFieldExists, key, field));
                    commands.Add(new RedisCommand("HDEL", key, field));
                    break;
                }

                case RowInsert insert:
                {
                    var field = Text(Get(insert.Values, RedisKeyLayout.Field));
                    if (string.IsNullOrEmpty(field))
                    {
                        throw new NotSupportedException("A new hash row needs a field name.");
                    }

                    guards.Add(new RedisGuard(RedisGuardKind.HashFieldMissing, key, field));
                    commands.Add(new RedisCommand("HSET", key, field, Text(Get(insert.Values, RedisKeyLayout.Value)) ?? string.Empty));
                    break;
                }
            }
        }
    }

    // Updates address rows by their position as the grid read them. Deletes overwrite each doomed element with a
    // marker and remove every marker at the end, so no delete shifts the positions another change relies on. New
    // values go to the tail.
    private static void PlanList(string key, IReadOnlyList<RowChange> changes, string marker, List<RedisGuard> guards, List<RedisCommand> commands)
    {
        var updates = new List<RedisCommand>();
        var deletes = new List<RedisCommand>();
        var inserts = new List<RedisCommand>();
        foreach (var change in changes)
        {
            switch (change)
            {
                case RowUpdate update:
                {
                    var index = ListIndex(update.Key);
                    if (TryGet(update.Values, RedisKeyLayout.Index, out var newIndex) && ParseIndex(newIndex) != index)
                    {
                        throw new NotSupportedException("A list element's position cannot be edited. Delete it and add the value again.");
                    }

                    if (!TryGet(update.Values, RedisKeyLayout.Value, out var value))
                    {
                        continue;
                    }

                    guards.Add(new RedisGuard(RedisGuardKind.ListIndexExists, key, Index: index));
                    updates.Add(new RedisCommand("LSET", key, Format(index), Text(value) ?? throw NullValue()));
                    break;
                }

                case RowDelete delete:
                {
                    var index = ListIndex(delete.Key);
                    guards.Add(new RedisGuard(RedisGuardKind.ListIndexExists, key, Index: index));
                    deletes.Add(new RedisCommand("LSET", key, Format(index), marker));
                    break;
                }

                case RowInsert insert:
                    inserts.Add(new RedisCommand("RPUSH", key, Text(Get(insert.Values, RedisKeyLayout.Value)) ?? string.Empty));
                    break;
            }
        }

        commands.AddRange(updates);
        commands.AddRange(deletes);
        if (deletes.Count > 0)
        {
            commands.Add(new RedisCommand("LREM", key, "0", marker));
        }

        commands.AddRange(inserts);
    }

    private static void PlanSet(string key, IReadOnlyList<RowChange> changes, List<RedisGuard> guards, List<RedisCommand> commands)
    {
        foreach (var change in changes)
        {
            switch (change)
            {
                case RowUpdate update:
                {
                    var member = RequiredKey(update.Key, RedisKeyLayout.Member, "set member");
                    if (!TryGet(update.Values, RedisKeyLayout.Member, out var value))
                    {
                        continue;
                    }

                    var renamed = Text(value) ?? throw NullValue();
                    if (renamed == member)
                    {
                        continue;
                    }

                    guards.Add(new RedisGuard(RedisGuardKind.SetContains, key, member));
                    commands.Add(new RedisCommand("SREM", key, member));
                    commands.Add(new RedisCommand("SADD", key, renamed));
                    break;
                }

                case RowDelete delete:
                {
                    var member = RequiredKey(delete.Key, RedisKeyLayout.Member, "set member");
                    guards.Add(new RedisGuard(RedisGuardKind.SetContains, key, member));
                    commands.Add(new RedisCommand("SREM", key, member));
                    break;
                }

                case RowInsert insert:
                    commands.Add(new RedisCommand("SADD", key, Text(Get(insert.Values, RedisKeyLayout.Member)) ?? throw NullValue()));
                    break;
            }
        }
    }

    private static void PlanSortedSet(string key, IReadOnlyList<RowChange> changes, IReadOnlyDictionary<string, string?> current, List<RedisGuard> guards, List<RedisCommand> commands)
    {
        foreach (var change in changes)
        {
            switch (change)
            {
                case RowUpdate update:
                {
                    var member = RequiredKey(update.Key, RedisKeyLayout.Member, "sorted set member");
                    var renamed = TryGet(update.Values, RedisKeyLayout.Member, out var newMember) ? Text(newMember) ?? throw NullValue() : member;
                    var hasScore = TryGet(update.Values, RedisKeyLayout.Score, out var newScore);
                    guards.Add(new RedisGuard(RedisGuardKind.SortedSetContains, key, member));
                    if (renamed != member)
                    {
                        var score = hasScore
                            ? Score(newScore)
                            : current.TryGetValue(member, out var read) && read is not null
                                ? Score(read)
                                : throw new InvalidOperationException($"The sorted set member '{member}' no longer exists, so nothing was saved.");
                        commands.Add(new RedisCommand("ZREM", key, member));
                        commands.Add(new RedisCommand("ZADD", key, score, renamed));
                    }
                    else if (hasScore)
                    {
                        commands.Add(new RedisCommand("ZADD", key, Score(newScore), member));
                    }
                    else
                    {
                        guards.RemoveAt(guards.Count - 1);
                    }

                    break;
                }

                case RowDelete delete:
                {
                    var member = RequiredKey(delete.Key, RedisKeyLayout.Member, "sorted set member");
                    guards.Add(new RedisGuard(RedisGuardKind.SortedSetContains, key, member));
                    commands.Add(new RedisCommand("ZREM", key, member));
                    break;
                }

                case RowInsert insert:
                {
                    var member = Text(Get(insert.Values, RedisKeyLayout.Member)) ?? throw NullValue();
                    var score = TryGet(insert.Values, RedisKeyLayout.Score, out var given) && given is not null ? Score(given) : "0";
                    commands.Add(new RedisCommand("ZADD", key, score, member));
                    break;
                }
            }
        }
    }

    private static void PlanStream(string key, IReadOnlyList<RowChange> changes, List<RedisCommand> commands)
    {
        foreach (var change in changes)
        {
            switch (change)
            {
                case RowUpdate:
                    throw new NotSupportedException("Stream entries cannot change once added. Delete the entry and add a new one.");
                case RowDelete delete:
                    commands.Add(new RedisCommand("XDEL", key, RequiredKey(delete.Key, RedisKeyLayout.Id, "stream entry id")));
                    break;
                case RowInsert insert:
                {
                    var id = Text(Get(insert.Values, RedisKeyLayout.Id));
                    var json = Text(Get(insert.Values, RedisKeyLayout.Fields));
                    if (string.IsNullOrWhiteSpace(json))
                    {
                        throw new NotSupportedException("A new stream entry needs its fields as a JSON object, such as {\"name\": \"value\"}.");
                    }

                    IReadOnlyList<KeyValuePair<string, string>> fields;
                    try
                    {
                        fields = RedisJson.ReadFields(json);
                    }
                    catch (Exception ex) when (ex is JsonException or FormatException)
                    {
                        throw new NotSupportedException("A stream entry's fields must be a JSON object: " + ex.Message, ex);
                    }

                    if (fields.Count == 0)
                    {
                        throw new NotSupportedException("A stream entry needs at least one field.");
                    }

                    var args = new List<string>(2 + (fields.Count * 2)) { key, string.IsNullOrWhiteSpace(id) ? "*" : id.Trim() };
                    foreach (var (name, value) in fields)
                    {
                        args.Add(name);
                        args.Add(value);
                    }

                    commands.Add(new RedisCommand("XADD", args));
                    break;
                }
            }
        }
    }

    private static void PlanJson(string key, IReadOnlyList<RowChange> changes, List<RedisCommand> commands)
    {
        foreach (var change in changes)
        {
            switch (change)
            {
                case RowUpdate update:
                {
                    var path = RequiredKey(update.Key, RedisKeyLayout.Path, "JSON path");
                    if (TryGet(update.Values, RedisKeyLayout.Path, out var newPath) && Text(newPath) != path)
                    {
                        throw new NotSupportedException("A JSON member's path cannot be edited. Delete it and add the value under the new path.");
                    }

                    if (TryGet(update.Values, RedisKeyLayout.Value, out var value))
                    {
                        commands.Add(new RedisCommand("JSON.SET", key, path, JsonArgument(value)));
                    }

                    break;
                }

                case RowDelete delete:
                    commands.Add(new RedisCommand("JSON.DEL", key, RequiredKey(delete.Key, RedisKeyLayout.Path, "JSON path")));
                    break;
                case RowInsert insert:
                {
                    var path = Text(Get(insert.Values, RedisKeyLayout.Path));
                    if (string.IsNullOrWhiteSpace(path))
                    {
                        throw new NotSupportedException("A new JSON member needs a path, such as $.name.");
                    }

                    commands.Add(new RedisCommand("JSON.SET", key, path.Trim(), JsonArgument(Get(insert.Values, RedisKeyLayout.Value))));
                    break;
                }
            }
        }
    }

    /// <summary>Text that already reads as JSON is sent as it is; anything else is stored as a JSON string.</summary>
    public static string JsonArgument(object? value)
    {
        var text = Text(value);
        if (text is null)
        {
            return "null";
        }

        try
        {
            using var _ = JsonDocument.Parse(text);
            return text;
        }
        catch (JsonException)
        {
            return RedisJson.Quote(text);
        }
    }

    public static string? Text(object? value) => value switch
    {
        null or DBNull => null,
        string s => s,
        double d => d.ToString("R", CultureInfo.InvariantCulture),
        float f => f.ToString("R", CultureInfo.InvariantCulture),
        byte[] bytes => RedisReply.DecodeText(bytes),
        IFormattable formattable => formattable.ToString(null, CultureInfo.InvariantCulture),
        _ => value.ToString(),
    };

    private static string Score(object? value)
    {
        var text = Text(value)?.Trim();
        var score = RedisReplyShaper.ParseScore(text);
        return score switch
        {
            null => throw new NotSupportedException($"'{text}' is not a score. A score is a number, inf or -inf."),
            double.PositiveInfinity => "+inf",
            double.NegativeInfinity => "-inf",
            var s => s.Value.ToString("R", CultureInfo.InvariantCulture),
        };
    }

    private static long ListIndex(IReadOnlyDictionary<string, object?> key) =>
        ParseIndex(Get(key, RedisKeyLayout.Index)) ?? throw new NotSupportedException("The row has no list position, so it cannot be addressed.");

    private static long? ParseIndex(object? value) => value switch
    {
        long l => l,
        int i => i,
        _ => long.TryParse(Text(value), NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var parsed) ? parsed : null,
    };

    private static string Format(long value) => value.ToString(CultureInfo.InvariantCulture);

    private static string RequiredKey(IReadOnlyDictionary<string, object?> key, string column, string what) =>
        Text(Get(key, column)) ?? throw new NotSupportedException($"The row has no {what}, so it cannot be addressed.");

    private static NotSupportedException NullValue() =>
        new("Redis cannot store NULL. Enter an empty value instead.");

    private static object? Get(IReadOnlyDictionary<string, object?> values, string column) =>
        TryGet(values, column, out var value) ? value : null;

    private static bool TryGet(IReadOnlyDictionary<string, object?> values, string column, out object? value)
    {
        if (values.TryGetValue(column, out value))
        {
            return true;
        }

        foreach (var (name, v) in values)
        {
            if (string.Equals(name, column, StringComparison.OrdinalIgnoreCase))
            {
                value = v;
                return true;
            }
        }

        value = null;
        return false;
    }
}
