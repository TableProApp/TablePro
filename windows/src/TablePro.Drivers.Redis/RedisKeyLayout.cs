using System.Globalization;
using System.Text.Json;
using TablePro.Core.Browse;
using TablePro.Core.Results;
using TablePro.Core.Schema;

namespace TablePro.Drivers.Redis;

/// <summary>
/// How each type of key reads as a table: its columns, which of them names a row (the grid's primary key), and how a
/// page of the type's reply becomes rows.
/// </summary>
internal static class RedisKeyLayout
{
    public const string Value = "value";
    public const string Field = "field";
    public const string Index = "index";
    public const string Member = "member";
    public const string Score = "score";
    public const string Id = "id";
    public const string Fields = "fields";
    public const string Path = "path";

    private static readonly ResultColumn ValueText = new(Value, "string", typeof(string));
    private static readonly ResultColumn JsonValue = new(Value, "json", typeof(string));

    public static IReadOnlyList<ResultColumn> Columns(RedisKeyType type) => type switch
    {
        RedisKeyType.String => [ValueText],
        RedisKeyType.Hash => [new(Field, "string", typeof(string)), ValueText],
        RedisKeyType.List => [new(Index, "integer", typeof(long)), ValueText],
        RedisKeyType.Set => [new(Member, "string", typeof(string))],
        RedisKeyType.SortedSet => [new(Member, "string", typeof(string)), new(Score, "double", typeof(double))],
        RedisKeyType.Stream => [new(Id, "stream id", typeof(string)), new(Fields, "json", typeof(string))],
        RedisKeyType.Json => [new(Path, "json path", typeof(string)), JsonValue],
        _ => [ValueText],
    };

    /// <summary>
    /// The column that names a row. A string's only row is named by its value, which lets a save check the value is
    /// still the one the grid showed.
    /// </summary>
    public static string KeyColumn(RedisKeyType type) => type switch
    {
        RedisKeyType.Hash => Field,
        RedisKeyType.List => Index,
        RedisKeyType.Set or RedisKeyType.SortedSet => Member,
        RedisKeyType.Stream => Id,
        RedisKeyType.Json => Path,
        _ => Value,
    };

    public static IReadOnlyList<ColumnInfo> StructureColumns(RedisKeyType type)
    {
        var keyColumn = KeyColumn(type);
        return Columns(type)
            .Select((c, i) => new ColumnInfo(
                c.Name,
                c.DataType,
                IsNullable: false,
                DefaultValue: c.Name == Score ? "0" : null,
                IsPrimaryKey: c.Name == keyColumn,
                IsIdentity: type == RedisKeyType.List && c.Name == Index,
                Ordinal: i + 1,
                Comment: ColumnComment(type, c.Name)))
            .ToArray();
    }

    public static ResultSet StringRows(string? value) => new(Columns(RedisKeyType.String), [[value]]);

    public static ResultSet HashRows(IReadOnlyList<RedisReply> fieldsAndValues, bool more)
    {
        var columns = Columns(RedisKeyType.Hash);
        var set = RedisReplyShaper.Pairs(fieldsAndValues, columns[0], columns[1], int.MaxValue);
        return more ? new ResultSet(set.Columns, [.. set.Rows], true) : set;
    }

    public static ResultSet ListRows(IReadOnlyList<RedisReply> items, long offset, bool more)
    {
        var rows = new List<object?[]>(items.Count);
        for (var i = 0; i < items.Count; i++)
        {
            rows.Add([offset + i, RedisReplyShaper.CellText(items[i])]);
        }

        return new ResultSet(Columns(RedisKeyType.List), rows, more);
    }

    public static ResultSet SetRows(IReadOnlyList<RedisReply> members, bool more)
    {
        var rows = new List<object?[]>(members.Count);
        foreach (var member in members)
        {
            rows.Add([RedisReplyShaper.CellText(member)]);
        }

        return new ResultSet(Columns(RedisKeyType.Set), rows, more);
    }

    public static ResultSet SortedSetRows(IReadOnlyList<RedisReply> membersAndScores, bool more)
    {
        var columns = Columns(RedisKeyType.SortedSet);
        var set = RedisReplyShaper.Pairs(membersAndScores, columns[0], columns[1], int.MaxValue);
        return more ? new ResultSet(set.Columns, [.. set.Rows], true) : set;
    }

    public static ResultSet StreamRows(IReadOnlyList<RedisReply> entries, bool more)
    {
        var set = RedisReplyShaper.StreamEntries(entries, int.MaxValue);
        return more ? new ResultSet(set.Columns, [.. set.Rows], true) : set;
    }

    /// <summary>
    /// A ReJSON document as rows: an object's members and an array's elements one per row with the JSONPath that
    /// addresses each, and a scalar document as the single row <c>$</c>.
    /// </summary>
    public static IReadOnlyList<(string Path, string Value)> JsonRows(string? json)
    {
        if (string.IsNullOrWhiteSpace(json))
        {
            return [];
        }

        using var document = JsonDocument.Parse(json);
        var root = document.RootElement;
        var rows = new List<(string, string)>();
        switch (root.ValueKind)
        {
            case JsonValueKind.Object:
                foreach (var property in root.EnumerateObject())
                {
                    rows.Add((MemberPath(property.Name), property.Value.GetRawText()));
                }

                break;
            case JsonValueKind.Array:
                var i = 0;
                foreach (var element in root.EnumerateArray())
                {
                    rows.Add((string.Create(CultureInfo.InvariantCulture, $"$[{i++}]"), element.GetRawText()));
                }

                break;
            default:
                rows.Add(("$", root.GetRawText()));
                break;
        }

        return rows;
    }

    public static ResultSet JsonResult(IReadOnlyList<(string Path, string Value)> rows, int offset, int limit)
    {
        var page = rows.Skip(offset).Take(limit).Select(r => new object?[] { r.Path, r.Value }).ToList();
        return new ResultSet(Columns(RedisKeyType.Json), page, offset + page.Count < rows.Count);
    }

    /// <summary><c>$.name</c> for a plain identifier, otherwise the bracket form with the name quoted.</summary>
    public static string MemberPath(string name)
    {
        var plain = name.Length > 0 && (char.IsLetter(name[0]) || name[0] == '_') && name.All(c => char.IsLetterOrDigit(c) || c == '_');
        return plain ? "$." + name : "$[" + RedisJson.Quote(name) + "]";
    }

    /// <summary>
    /// Applies the filter strip to one page of rows. Redis has no server-side filter on a value's contents, so only
    /// the rows already read are matched; a page may come back shorter than the limit.
    /// </summary>
    public static ResultSet ApplyFilter(ResultSet page, BrowseFilter filter)
    {
        if (!string.IsNullOrWhiteSpace(filter.RawWhere))
        {
            throw new NotSupportedException("Redis has no WHERE clause. Use the filter rules, or SCAN with MATCH in the query editor.");
        }

        var rules = filter.Rules.Where(r => r.Enabled).ToArray();
        if (rules.Length == 0)
        {
            return page;
        }

        var kept = new List<object?[]>(page.RowCount);
        foreach (var row in page.Rows)
        {
            var matches = filter.MatchAll ? rules.All(r => Matches(page, row, r, filter.SearchColumns)) : rules.Any(r => Matches(page, row, r, filter.SearchColumns));
            if (matches)
            {
                kept.Add(row);
            }
        }

        return new ResultSet(page.Columns, kept, page.IsTruncated);
    }

    /// <summary>Orders a page by the requested columns, numbers as numbers and text ordinally.</summary>
    public static ResultSet ApplySort(ResultSet page, IReadOnlyList<SortColumn> sort)
    {
        var keys = sort.Select(s => (Index: page.ColumnIndex(s.Column), s.Descending)).Where(k => k.Index >= 0).ToArray();
        if (keys.Length == 0 || page.RowCount < 2)
        {
            return page;
        }

        var rows = page.Rows.ToList();
        rows.Sort((a, b) =>
        {
            foreach (var (index, descending) in keys)
            {
                var order = CompareCells(a[index], b[index]);
                if (order != 0)
                {
                    return descending ? -order : order;
                }
            }

            return 0;
        });
        return new ResultSet(page.Columns, rows, page.IsTruncated);
    }

    public static bool Matches(ResultSet page, object?[] row, FilterRule rule, IReadOnlyList<string> searchColumns)
    {
        if (rule.Column is null)
        {
            var columns = searchColumns.Count > 0 ? searchColumns : page.Columns.Select(c => c.Name).ToArray();
            var indexes = columns.Select(page.ColumnIndex).Where(i => i >= 0).ToArray();
            var negative = rule.Operator is FilterOperator.NotEquals or FilterOperator.NotContains or FilterOperator.NotIn or FilterOperator.IsNotEmpty or FilterOperator.IsNotNull;
            return negative ? indexes.All(i => MatchesCell(row[i], rule)) : indexes.Any(i => MatchesCell(row[i], rule));
        }

        var column = page.ColumnIndex(rule.Column);
        return column < 0 || MatchesCell(row[column], rule);
    }

    public static bool MatchesCell(object? cell, FilterRule rule)
    {
        var text = cell switch
        {
            null => null,
            double d => d.ToString("R", CultureInfo.InvariantCulture),
            IFormattable f => f.ToString(null, CultureInfo.InvariantCulture),
            _ => cell.ToString(),
        };
        var value = rule.Value ?? string.Empty;
        return rule.Operator switch
        {
            FilterOperator.IsNull => text is null,
            FilterOperator.IsNotNull => text is not null,
            FilterOperator.IsEmpty => string.IsNullOrEmpty(text),
            FilterOperator.IsNotEmpty => !string.IsNullOrEmpty(text),
            _ when text is null => false,
            FilterOperator.Equals => Compare(text, value) == 0,
            FilterOperator.NotEquals => Compare(text, value) != 0,
            FilterOperator.GreaterThan => Order(text, value) > 0,
            FilterOperator.GreaterOrEqual => Order(text, value) >= 0,
            FilterOperator.LessThan => Order(text, value) < 0,
            FilterOperator.LessOrEqual => Order(text, value) <= 0,
            FilterOperator.Contains => text.Contains(value, StringComparison.OrdinalIgnoreCase),
            FilterOperator.NotContains => !text.Contains(value, StringComparison.OrdinalIgnoreCase),
            FilterOperator.StartsWith => text.StartsWith(value, StringComparison.OrdinalIgnoreCase),
            FilterOperator.EndsWith => text.EndsWith(value, StringComparison.OrdinalIgnoreCase),
            FilterOperator.In => SplitList(value).Any(v => Compare(text, v) == 0),
            FilterOperator.NotIn => !SplitList(value).Any(v => Compare(text, v) == 0),
            FilterOperator.Between => Order(text, value) >= 0 && Order(text, rule.SecondValue ?? string.Empty) <= 0,
            _ => true,
        };
    }

    // A range against a number only matches values that are numbers; "Ada" is not greater than 9.
    private static int? Order(string left, string right)
    {
        var leftNumber = double.TryParse(left, NumberStyles.Float, CultureInfo.InvariantCulture, out var l);
        var rightNumber = double.TryParse(right, NumberStyles.Float, CultureInfo.InvariantCulture, out var r);
        return leftNumber && rightNumber ? l.CompareTo(r)
            : leftNumber || rightNumber ? null
            : string.Compare(left, right, StringComparison.Ordinal);
    }

    private static IEnumerable<string> SplitList(string value) =>
        value.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries).Select(v => v.Trim('\'', '"'));

    // Both sides as numbers when both read as one, so 10 sorts after 9; otherwise ordinal text.
    private static int Compare(string left, string right) =>
        double.TryParse(left, NumberStyles.Float, CultureInfo.InvariantCulture, out var l) && double.TryParse(right, NumberStyles.Float, CultureInfo.InvariantCulture, out var r)
            ? l.CompareTo(r)
            : string.Compare(left, right, StringComparison.Ordinal);

    private static int CompareCells(object? a, object? b) => (a, b) switch
    {
        (null, null) => 0,
        (null, _) => -1,
        (_, null) => 1,
        (long x, long y) => x.CompareTo(y),
        (double x, double y) => x.CompareTo(y),
        _ => Compare(Convert.ToString(a, CultureInfo.InvariantCulture) ?? string.Empty, Convert.ToString(b, CultureInfo.InvariantCulture) ?? string.Empty),
    };

    private static string? ColumnComment(RedisKeyType type, string column) => (type, column) switch
    {
        (RedisKeyType.List, Index) => "Position from the head, starting at 0",
        (RedisKeyType.Stream, Id) => "Leave empty when adding to let the server assign one",
        (RedisKeyType.Stream, Fields) => "A JSON object of field names to values",
        (RedisKeyType.Json, Path) => "JSONPath of the member",
        (RedisKeyType.Json, Value) => "JSON text",
        _ => null,
    };
}
