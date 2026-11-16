using TablePro.Interop;

namespace TablePro.App.Model;

// The grid's Filter by a cell's value, as macOS offers it: equal or not, greater or less where the column orders, and
// the NULL tests for a NULL cell. Each rule is one of the operators the engine offers for the column.
public static class CellFilters
{
    // A longer value would make a menu title and a statement no one reads.
    public const int MaximumValueLength = 10_000;

    private static readonly FilterOperator[] ForNull = [FilterOperator.IsNull, FilterOperator.IsNotNull];

    private static readonly FilterOperator[] ForValue =
        [FilterOperator.Equal, FilterOperator.NotEqual, FilterOperator.Greater, FilterOperator.Less];

    // filterText is the core's text that binds back to the value stored, null where none does. None for a binary
    // value, a value cut short or too long, one that starts or ends with a blank, which a filter row reads trimmed, one
    // that reads as the NULL literal, and a cell holding an edit not saved yet.
    public static IReadOnlyList<FilterRule> For(
        string column,
        IReadOnlyList<FilterOperator> offered,
        CellValue? value,
        string? filterText,
        bool pending)
    {
        ArgumentNullException.ThrowIfNull(column);
        ArgumentNullException.ThrowIfNull(offered);
        if (value is null || pending || value.IsDefault || value.Bytes is not null)
        {
            return [];
        }

        if (value.IsNull)
        {
            return [.. ForNull.Where(offered.Contains).Select(op => new FilterRule(column, op, null))];
        }

        var text = filterText ?? string.Empty;
        if (value.TextCut
            || text.Length == 0
            || text.Length > MaximumValueLength
            || char.IsWhiteSpace(text[0])
            || char.IsWhiteSpace(text[^1])
            || string.Equals(text, "NULL", StringComparison.OrdinalIgnoreCase))
        {
            return [];
        }

        return [.. ForValue.Where(offered.Contains).Select(op => new FilterRule(column, op, new FilterValue.One(text)))];
    }

    // The rule joins the rules running under Match all; under Match any with two clauses running it runs alone, as
    // macOS adds it. A rule already running leaves the filter as it is.
    public static TableFilter With(TableFilter? current, FilterRule rule)
    {
        ArgumentNullException.ThrowIfNull(rule);
        if (current is null)
        {
            return new TableFilter(FilterCombinator.And, [rule], null);
        }

        var single = new TableFilter(FilterCombinator.And, [rule], null);
        if (current.Rules.Any(running => TableFilters.Same(
            new TableFilter(FilterCombinator.And, [running], null), single)))
        {
            return current;
        }

        var clauses = current.Rules.Count + (string.IsNullOrWhiteSpace(current.RawSql) ? 0 : 1);
        return current.Combinator == FilterCombinator.Or && clauses >= 2
            ? single
            : new TableFilter(FilterCombinator.And, [.. current.Rules, rule], current.RawSql);
    }
}
