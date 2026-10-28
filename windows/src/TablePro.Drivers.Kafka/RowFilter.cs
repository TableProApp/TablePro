using System.Globalization;
using System.Text;
using TablePro.Core.Browse;
using TablePro.Core.Results;

namespace TablePro.Drivers.Kafka;

/// <summary>
/// The filter strip's rules evaluated over messages already read, since a broker cannot filter. Text comparisons
/// ignore case, as the SQL engines' LIKE filters do; ordering compares numbers when both sides are numbers.
/// </summary>
internal static class RowFilter
{
    public static Func<object?[], bool> Compile(BrowseFilter filter, IReadOnlyList<string> columns)
    {
        if (!string.IsNullOrWhiteSpace(filter.RawWhere))
        {
            throw new NotSupportedException("Kafka cannot run a raw WHERE clause; use the filter rules instead.");
        }

        var rules = filter.Rules.Where(r => r.Enabled).ToArray();
        if (rules.Length == 0)
        {
            return static _ => true;
        }

        var search = filter.SearchColumns.Count > 0 ? filter.SearchColumns : columns;
        var tests = rules.Select(rule => Compile(rule, columns, search)).ToArray();
        return filter.MatchAll ? row => tests.All(t => t(row)) : row => tests.Any(t => t(row));
    }

    private static Func<object?[], bool> Compile(FilterRule rule, IReadOnlyList<string> columns, IReadOnlyList<string> search)
    {
        var value = rule.Value ?? string.Empty;
        if (rule.Column is null)
        {
            var ordinals = search.Select(c => IndexOf(columns, c)).Where(i => i >= 0).ToArray();
            return row => value.Length == 0 || ordinals.Any(i => Text(row[i])?.Contains(value, StringComparison.OrdinalIgnoreCase) == true);
        }

        var ordinal = IndexOf(columns, rule.Column);
        if (ordinal < 0)
        {
            throw new NotSupportedException($"There is no column named {rule.Column} to filter on.");
        }

        var list = value.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
        return rule.Operator switch
        {
            FilterOperator.Equals => row => Compare(row[ordinal], value) == 0,
            FilterOperator.NotEquals => row => Compare(row[ordinal], value) != 0,
            FilterOperator.GreaterThan => row => Compare(row[ordinal], value) > 0,
            FilterOperator.GreaterOrEqual => row => Compare(row[ordinal], value) >= 0,
            FilterOperator.LessThan => row => Compare(row[ordinal], value) < 0,
            FilterOperator.LessOrEqual => row => Compare(row[ordinal], value) <= 0,
            FilterOperator.Contains => row => Text(row[ordinal])?.Contains(value, StringComparison.OrdinalIgnoreCase) == true,
            FilterOperator.NotContains => row => Text(row[ordinal])?.Contains(value, StringComparison.OrdinalIgnoreCase) != true,
            FilterOperator.StartsWith => row => Text(row[ordinal])?.StartsWith(value, StringComparison.OrdinalIgnoreCase) == true,
            FilterOperator.EndsWith => row => Text(row[ordinal])?.EndsWith(value, StringComparison.OrdinalIgnoreCase) == true,
            FilterOperator.IsNull => row => row[ordinal] is null,
            FilterOperator.IsNotNull => row => row[ordinal] is not null,
            FilterOperator.IsEmpty => row => string.IsNullOrEmpty(Text(row[ordinal])),
            FilterOperator.IsNotEmpty => row => !string.IsNullOrEmpty(Text(row[ordinal])),
            FilterOperator.In => row => list.Any(item => Compare(row[ordinal], item) == 0),
            FilterOperator.NotIn => row => !list.Any(item => Compare(row[ordinal], item) == 0),
            FilterOperator.Between => row => Compare(row[ordinal], value) >= 0 && Compare(row[ordinal], rule.SecondValue ?? string.Empty) <= 0,
            _ => static _ => true,
        };
    }

    private static int IndexOf(IReadOnlyList<string> columns, string name)
    {
        for (var i = 0; i < columns.Count; i++)
        {
            if (string.Equals(columns[i], name, StringComparison.OrdinalIgnoreCase))
            {
                return i;
            }
        }

        return -1;
    }

    // Bytes are matched as the UTF-8 they may hold; everything else as the grid shows it.
    private static string? Text(object? value) => value switch
    {
        null => null,
        byte[] bytes => Encoding.UTF8.GetString(bytes),
        _ => CellFormatter.Format(value),
    };

    private static int Compare(object? cell, string value)
    {
        if (cell is null)
        {
            return -1;
        }

        var text = Text(cell) ?? string.Empty;
        if (double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var left)
            && double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out var right))
        {
            return left.CompareTo(right);
        }

        return string.Compare(text, value, StringComparison.OrdinalIgnoreCase);
    }
}
