using System.Globalization;
using TablePro.Core.Browse;
using TablePro.Core.Results;
using TablePro.Core.Sql;
using TablePro.Drivers.Cassandra.Localization;

namespace TablePro.Drivers.Cassandra;

/// <summary>How a table page is read: the CQL sent, what is filtered on the rows that come back, and what the user is told.</summary>
public sealed record CqlBrowsePlan(string Cql, string CountCql, object?[] Values, CqlRowFilter? ClientFilter, IReadOnlyList<string> Notices)
{
    /// <summary>Identifies the statement and its values, which a saved paging state is only valid for.</summary>
    public string ResumeKey => Values.Length == 0 ? Cql : Cql + "\u001f" + string.Join("\u001f", Values);
}

/// <summary>
/// Splits a browse filter into what CQL evaluates and what is checked on the rows read. Without ALLOW FILTERING the
/// server only takes a restriction of the whole partition key by equality, so anything else either goes to the server
/// with ALLOW FILTERING (when the connection opts in) or is filtered on each page as it arrives.
/// </summary>
public static class CqlBrowsePlanner
{
    private static SqlDialect Dialect => CqlDialect.Instance;

    public static CqlBrowsePlan Plan(BrowseRequest request, CqlTableShape shape, bool allowFiltering)
    {
        var notices = new List<string>();
        if (request.Sort.Count > 0)
        {
            notices.Add(CassandraStrings.Get("Cassandra/SortNotApplied"));
        }

        var filter = request.Filter;
        var rules = filter.Rules.Where(r => r.Enabled).ToList();
        var server = new List<FilterRule>();
        var client = new List<FilterRule>();

        if (!filter.MatchAll && rules.Count > 1)
        {
            // CQL joins restrictions only with AND.
            client.AddRange(rules);
        }
        else if (allowFiltering)
        {
            foreach (var rule in rules)
            {
                (IsServerRule(rule, shape) ? server : client).Add(rule);
            }
        }
        else
        {
            var partitionRules = rules.Where(r => IsPartitionRule(r, shape)).ToList();
            var covered = partitionRules.Count > 0 && IsPartitionLookup(partitionRules, shape);
            foreach (var rule in rules)
            {
                (covered && partitionRules.Contains(rule) ? server : client).Add(rule);
            }
        }

        var values = new List<object?>();
        var where = new List<string>();
        foreach (var rule in server)
        {
            where.Add(Render(rule, shape, values));
        }

        var raw = filter.RawWhere?.Trim();
        if (!string.IsNullOrEmpty(raw))
        {
            where.Add(raw);
            if (!filter.MatchAll && rules.Count > 0)
            {
                notices.Add(CassandraStrings.Get("Cassandra/RawConditionAnd"));
            }
        }

        // A lookup of whole partitions is served by the key and needs no ALLOW FILTERING.
        var isPartitionLookup = server.Count > 0 && IsPartitionLookup(server, shape);
        var needsFiltering = allowFiltering && ((server.Count > 0 && !isPartitionLookup) || !string.IsNullOrEmpty(raw));

        var whereText = where.Count == 0 ? string.Empty : " WHERE " + string.Join(" AND ", where) + (needsFiltering ? " ALLOW FILTERING" : string.Empty);
        var table = Dialect.Qualify(shape.Table);

        CqlRowFilter? clientFilter = null;
        if (client.Count > 0)
        {
            clientFilter = new CqlRowFilter(client, filter.MatchAll || rules.Count <= 1, filter.SearchColumns);
            notices.Add(allowFiltering
                ? CassandraStrings.Plural("Cassandra/ClientRules", client.Count)
                : CassandraStrings.Plural("Cassandra/ClientRulesNoAllowFiltering", client.Count));
        }

        return new CqlBrowsePlan($"SELECT * FROM {table}{whereText}", $"SELECT COUNT(*) FROM {table}{whereText}", [.. values], clientFilter, notices);
    }

    private static bool IsPartitionRule(FilterRule rule, CqlTableShape shape) =>
        rule.Operator is FilterOperator.Equals or FilterOperator.In
        && rule.Column is not null
        && shape.Column(rule.Column)?.IsPartitionKey == true
        && IsServerRule(rule, shape);

    private static bool IsPartitionLookup(IReadOnlyList<FilterRule> rules, CqlTableShape shape) =>
        rules.All(r => IsPartitionRule(r, shape)) && shape.PartitionKey.All(k => rules.Any(r => r.Column == k));

    private static bool IsServerRule(FilterRule rule, CqlTableShape shape) =>
        rule.Column is not null
        && shape.Column(rule.Column) is { } column
        && !CqlTableShape.IsCompositeType(column.Type)
        && rule.Operator switch
        {
            FilterOperator.Equals or FilterOperator.GreaterThan or FilterOperator.GreaterOrEqual or FilterOperator.LessThan or FilterOperator.LessOrEqual => true,
            FilterOperator.In => Items(rule.Value).Length > 0,
            FilterOperator.Between => !string.IsNullOrEmpty(rule.Value) && !string.IsNullOrEmpty(rule.SecondValue),
            _ => false,
        };

    private static string Render(FilterRule rule, CqlTableShape shape, List<object?> values)
    {
        var column = Dialect.QuoteIdentifier(rule.Column!);
        return rule.Operator switch
        {
            FilterOperator.Equals => $"{column} = {Bind(values, rule.Value)}",
            FilterOperator.GreaterThan => $"{column} > {Bind(values, rule.Value)}",
            FilterOperator.GreaterOrEqual => $"{column} >= {Bind(values, rule.Value)}",
            FilterOperator.LessThan => $"{column} < {Bind(values, rule.Value)}",
            FilterOperator.LessOrEqual => $"{column} <= {Bind(values, rule.Value)}",
            FilterOperator.In => $"{column} IN ({string.Join(", ", Items(rule.Value).Select(v => Bind(values, v)))})",
            FilterOperator.Between => $"{column} >= {Bind(values, rule.Value)} AND {column} <= {Bind(values, rule.SecondValue)}",
            _ => throw new ArgumentOutOfRangeException(nameof(rule)),
        };
    }

    // Typed text goes through fromJson as a JSON string, which every scalar CQL type parses from its text form.
    private static string Bind(List<object?> values, string? text)
    {
        values.Add(CqlCellMapper.ToJson(text ?? string.Empty));
        return "fromJson(?)";
    }

    private static string[] Items(string? csv) =>
        (csv ?? string.Empty).Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
}

/// <summary>Filter rules checked on decoded rows, with the same meaning the SQL engines give them.</summary>
public sealed class CqlRowFilter(IReadOnlyList<FilterRule> rules, bool matchAll, IReadOnlyList<string> searchColumns)
{
    public IReadOnlyList<FilterRule> Rules => rules;

    /// <summary>Resolves column names against a result once, so each row is checked by index.</summary>
    public Func<object?[], bool> Bind(IReadOnlyList<ResultColumn> columns)
    {
        var compiled = rules.Select(rule => Compile(rule, columns)).ToArray();
        return matchAll
            ? row => Array.TrueForAll(compiled, test => test(row))
            : row => Array.Exists(compiled, test => test(row));
    }

    private Func<object?[], bool> Compile(FilterRule rule, IReadOnlyList<ResultColumn> columns)
    {
        if (rule.Column is null)
        {
            var names = searchColumns.Count > 0 ? searchColumns : columns.Select(c => c.Name).ToList();
            var indexes = names.Select(n => IndexOf(columns, n)).Where(i => i >= 0).ToArray();
            var needle = rule.Value ?? string.Empty;
            return row => needle.Length == 0 || Array.Exists(indexes, i => Text(row[i])?.Contains(needle, StringComparison.OrdinalIgnoreCase) == true);
        }

        var index = IndexOf(columns, rule.Column);
        return row => Matches(rule, index < 0 ? null : row[index]);
    }

    public static bool Matches(FilterRule rule, object? cell)
    {
        var text = Text(cell);
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
            FilterOperator.GreaterThan => Compare(text, value) > 0,
            FilterOperator.GreaterOrEqual => Compare(text, value) >= 0,
            FilterOperator.LessThan => Compare(text, value) < 0,
            FilterOperator.LessOrEqual => Compare(text, value) <= 0,
            FilterOperator.Contains => text.Contains(value, StringComparison.OrdinalIgnoreCase),
            FilterOperator.NotContains => !text.Contains(value, StringComparison.OrdinalIgnoreCase),
            FilterOperator.StartsWith => text.StartsWith(value, StringComparison.OrdinalIgnoreCase),
            FilterOperator.EndsWith => text.EndsWith(value, StringComparison.OrdinalIgnoreCase),
            FilterOperator.In => Items(value).Any(item => Compare(text, item) == 0),
            FilterOperator.NotIn => !Items(value).Any(item => Compare(text, item) == 0),
            FilterOperator.Between => Compare(text, value) >= 0 && Compare(text, rule.SecondValue ?? string.Empty) <= 0,
            _ => true,
        };
    }

    /// <summary>Numbers compare as numbers, everything else as text without regard to case.</summary>
    public static int Compare(string left, string right)
    {
        if (decimal.TryParse(left, NumberStyles.Float, CultureInfo.InvariantCulture, out var a)
            && decimal.TryParse(right.Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out var b))
        {
            return a.CompareTo(b);
        }

        if (double.TryParse(left, NumberStyles.Float, CultureInfo.InvariantCulture, out var x)
            && double.TryParse(right.Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out var y))
        {
            return x.CompareTo(y);
        }

        return string.Compare(left, right, StringComparison.OrdinalIgnoreCase);
    }

    private static string? Text(object? cell) => cell is null ? null : CellFormatter.Format(cell);

    private static int IndexOf(IReadOnlyList<ResultColumn> columns, string name)
    {
        for (var i = 0; i < columns.Count; i++)
        {
            if (string.Equals(columns[i].Name, name, StringComparison.Ordinal))
            {
                return i;
            }
        }

        return -1;
    }

    private static string[] Items(string csv) => csv.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
}

/// <summary>
/// Remembered paging states, so the next page resumes on the server instead of reading every row before it again.
/// A state is kept with the count of matching rows before it, per statement and values.
/// </summary>
public sealed class CqlResumePoints(int maxStatements = 16, int maxPointsPerStatement = 256)
{
    private readonly Lock _lock = new();
    private readonly LinkedList<(string Key, SortedList<int, byte[]> Points)> _statements = new();

    public void Record(string key, int matchedBefore, byte[] pagingState)
    {
        lock (_lock)
        {
            var points = Touch(key, create: true)!;
            if (points.Count >= maxPointsPerStatement && !points.ContainsKey(matchedBefore))
            {
                points.RemoveAt(points.Count - 1);
            }

            points[matchedBefore] = pagingState;
        }
    }

    /// <summary>The furthest point at or before <paramref name="offset"/>, or the start of the table.</summary>
    public (int MatchedBefore, byte[]? PagingState) Find(string key, int offset)
    {
        lock (_lock)
        {
            var points = Touch(key, create: false);
            if (points is null)
            {
                return (0, null);
            }

            for (var i = points.Count - 1; i >= 0; i--)
            {
                if (points.Keys[i] <= offset)
                {
                    return (points.Keys[i], points.Values[i]);
                }
            }

            return (0, null);
        }
    }

    public void Clear()
    {
        lock (_lock)
        {
            _statements.Clear();
        }
    }

    private SortedList<int, byte[]>? Touch(string key, bool create)
    {
        for (var node = _statements.First; node is not null; node = node.Next)
        {
            if (node.Value.Key == key)
            {
                _statements.Remove(node);
                _statements.AddFirst(node);
                return node.Value.Points;
            }
        }

        if (!create)
        {
            return null;
        }

        if (_statements.Count >= maxStatements)
        {
            _statements.RemoveLast();
        }

        var points = new SortedList<int, byte[]>();
        _statements.AddFirst((key, points));
        return points;
    }
}
