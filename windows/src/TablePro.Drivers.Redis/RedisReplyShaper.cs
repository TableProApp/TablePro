using System.Collections.Frozen;
using System.Globalization;
using TablePro.Core.Results;

namespace TablePro.Drivers.Redis;

/// <summary>What one reply shows: its tables and the status lines that go under them.</summary>
internal sealed record ShapedReply(IReadOnlyList<ResultSet> ResultSets, IReadOnlyList<string> Messages)
{
    public static ShapedReply Of(ResultSet set, params string[] messages) => new([set], messages);
}

/// <summary>
/// Lays a reply out as redis-cli does, in rows: one value in a cell of its own, an array numbered from 1, a map or a
/// field-value reply by its fields, and an element that is itself an array or a map as JSON text in one cell.
/// </summary>
internal static class RedisReplyShaper
{
    private static readonly ResultColumn IndexColumn = new("index", "integer", typeof(long));
    private static readonly ResultColumn TextValueColumn = new("value", "string", typeof(string));
    private static readonly ResultColumn IntegerValueColumn = new("value", "integer", typeof(long));
    private static readonly ResultColumn DoubleValueColumn = new("value", "double", typeof(double));
    private static readonly ResultColumn FieldColumn = new("field", "string", typeof(string));
    private static readonly ResultColumn MemberColumn = new("member", "string", typeof(string));
    private static readonly ResultColumn ScoreColumn = new("score", "double", typeof(double));
    private static readonly ResultColumn IdColumn = new("id", "string", typeof(string));
    private static readonly ResultColumn FieldsColumn = new("fields", "json", typeof(string));

    // Commands whose flat array reply alternates field and value.
    private static readonly FrozenSet<string> FieldValueCommands = FrozenSet.Create(StringComparer.OrdinalIgnoreCase,
        ["HGETALL", "CONFIG GET", "XINFO STREAM", "MEMORY STATS", "FT.INFO", "FT.CONFIG GET", "HELLO", "CLIENT TRACKINGINFO", "LATENCY DOCTOR", "COMMAND DOCS"]);

    // Commands that reply member, score, member, score when given WITHSCORES.
    private static readonly FrozenSet<string> ScoredCommands = FrozenSet.Create(StringComparer.OrdinalIgnoreCase,
        ["ZRANGE", "ZREVRANGE", "ZRANGEBYSCORE", "ZREVRANGEBYSCORE", "ZRANDMEMBER", "ZUNION", "ZINTER", "ZDIFF", "ZPOPMIN", "ZPOPMAX"]);

    public static ShapedReply Shape(IReadOnlyList<string> words, RedisReply reply, int rowLimit)
    {
        var verb = words.Count > 0 ? words[0].ToUpperInvariant() : string.Empty;
        var compound = words.Count > 1 ? $"{verb} {words[1].ToUpperInvariant()}" : verb;
        var limit = rowLimit > 0 ? rowLimit : int.MaxValue;

        if (reply.Kind == RedisReplyKind.Status && string.Equals(reply.Text, "OK", StringComparison.OrdinalIgnoreCase))
        {
            return new ShapedReply([], ["OK"]);
        }

        if (reply.Kind == RedisReplyKind.Text)
        {
            if (verb == "INFO")
            {
                return ShapedReply.Of(Limit(RedisServerText.InfoResult(reply.Text), limit));
            }

            if (compound is "CLIENT LIST" or "CLIENT INFO")
            {
                return ShapedReply.Of(Limit(RedisServerText.ParseClientList(reply.Text), limit));
            }
        }

        if (!reply.IsAggregate)
        {
            return ShapedReply.Of(Scalar(reply));
        }

        if (verb is "SCAN" or "SSCAN" or "HSCAN" or "ZSCAN" && reply.Items.Count == 2 && reply.Items[1].IsAggregate)
        {
            var cursor = reply.Items[0].Text ?? "0";
            var page = reply.Items[1].Items;
            var set = verb switch
            {
                "HSCAN" => Pairs(page, FieldColumn, TextValueColumn, limit),
                "ZSCAN" => Pairs(page, MemberColumn, ScoreColumn, limit),
                _ => Indexed(page, limit),
            };
            var note = cursor == "0" ? "Cursor 0: the scan is complete." : $"Next cursor: {cursor}";
            return ShapedReply.Of(set, note);
        }

        if (verb is "XRANGE" or "XREVRANGE")
        {
            return ShapedReply.Of(StreamEntries(reply.Items, limit));
        }

        if (reply.Kind == RedisReplyKind.Map || (FieldValueCommands.Contains(compound) || FieldValueCommands.Contains(verb) || IsFieldValueRandom(verb, words)) && IsFlatPairs(reply.Items))
        {
            return ShapedReply.Of(Pairs(reply.Items, FieldColumn, TextValueColumn, limit));
        }

        if (ScoredCommands.Contains(verb) && HasWord(words, "WITHSCORES"))
        {
            var items = FlattenPairs(reply.Items);
            if (IsFlatPairs(items))
            {
                return ShapedReply.Of(Pairs(items, MemberColumn, ScoreColumn, limit));
            }
        }

        return ShapedReply.Of(Indexed(reply.Items, limit));
    }

    /// <summary>One reply value in a cell named <c>value</c>, typed as the server typed it.</summary>
    public static ResultSet Scalar(RedisReply reply)
    {
        var (column, value) = reply.Kind switch
        {
            RedisReplyKind.Integer => (IntegerValueColumn, (object?)ParseLong(reply.Text)),
            RedisReplyKind.Double => (DoubleValueColumn, ParseScore(reply.Text)),
            RedisReplyKind.Null => (TextValueColumn, null),
            RedisReplyKind.Error => (TextValueColumn, "(error) " + reply.Text),
            _ when reply.IsAggregate => (TextValueColumn, RedisJson.Write(reply)),
            _ => (TextValueColumn, reply.Text),
        };
        return new ResultSet([column], [[value]]);
    }

    /// <summary>An array as numbered rows; integers keep a numeric column when every element is one.</summary>
    public static ResultSet Indexed(IReadOnlyList<RedisReply> items, int limit)
    {
        var count = Math.Min(items.Count, limit);
        var allIntegers = count > 0 && items.Take(count).All(i => i.Kind == RedisReplyKind.Integer);
        var rows = new List<object?[]>(count);
        for (var i = 0; i < count; i++)
        {
            rows.Add([(long)(i + 1), allIntegers ? ParseLong(items[i].Text) : CellText(items[i])]);
        }

        return new ResultSet([IndexColumn, allIntegers ? IntegerValueColumn : TextValueColumn], rows, items.Count > count);
    }

    public static ResultSet Pairs(IReadOnlyList<RedisReply> items, ResultColumn first, ResultColumn second, int limit)
    {
        var pairs = items.Count / 2;
        var count = Math.Min(pairs, limit);
        var rows = new List<object?[]>(count);
        for (var i = 0; i < count; i++)
        {
            var value = items[(i * 2) + 1];
            object? cell = second.ClrType == typeof(double) ? ParseScore(value.Text) : CellText(value);
            rows.Add([CellText(items[i * 2]), cell]);
        }

        return new ResultSet([first, second], rows, pairs > count);
    }

    /// <summary>XRANGE entries, each <c>[id, [field, value, ...]]</c>, as an id and its fields as one JSON object.</summary>
    public static ResultSet StreamEntries(IReadOnlyList<RedisReply> entries, int limit)
    {
        var count = Math.Min(entries.Count, limit);
        var rows = new List<object?[]>(count);
        for (var i = 0; i < count; i++)
        {
            var entry = entries[i];
            if (entry.Items.Count < 2)
            {
                continue;
            }

            rows.Add([entry.Items[0].Text, RedisJson.WriteFields(entry.Items[1].Items)]);
        }

        return new ResultSet([IdColumn, FieldsColumn], rows, entries.Count > count);
    }

    /// <summary>A cell's text: the value itself, or JSON for a nested array or map.</summary>
    public static string? CellText(RedisReply reply) => reply.Kind switch
    {
        RedisReplyKind.Null => null,
        RedisReplyKind.Error => "(error) " + reply.Text,
        _ when reply.IsAggregate => RedisJson.Write(reply),
        _ => reply.Text,
    };

    /// <summary>Redis writes infinite scores as <c>inf</c> and <c>-inf</c>, which .NET does not parse.</summary>
    public static double? ParseScore(string? text) => text?.Trim().ToLowerInvariant() switch
    {
        null => null,
        "inf" or "+inf" => double.PositiveInfinity,
        "-inf" => double.NegativeInfinity,
        var t => double.TryParse(t, NumberStyles.Float, CultureInfo.InvariantCulture, out var d) ? d : null,
    };

    private static long? ParseLong(string? text) =>
        long.TryParse(text, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var value) ? value : null;

    private static bool IsFieldValueRandom(string verb, IReadOnlyList<string> words) => verb == "HRANDFIELD" && HasWord(words, "WITHVALUES");

    private static bool HasWord(IReadOnlyList<string> words, string word)
    {
        for (var i = 1; i < words.Count; i++)
        {
            if (words[i].Equals(word, StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
        }

        return false;
    }

    private static bool IsFlatPairs(IReadOnlyList<RedisReply> items) =>
        items.Count % 2 == 0 && Enumerable.Range(0, items.Count / 2).All(i => !items[i * 2].IsAggregate);

    // RESP3 replies to WITHSCORES as [[member, score], ...] instead of a flat list.
    private static IReadOnlyList<RedisReply> FlattenPairs(IReadOnlyList<RedisReply> items) =>
        items.Count > 0 && items.All(i => i.Kind == RedisReplyKind.Array && i.Items.Count == 2)
            ? items.SelectMany(i => i.Items).ToArray()
            : items;

    private static ResultSet Limit(ResultSet set, int limit) =>
        set.RowCount <= limit ? set : new ResultSet(set.Columns, set.Rows.Take(limit).ToList(), true);
}
