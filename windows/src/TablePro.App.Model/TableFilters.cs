using TablePro.Interop;

namespace TablePro.App.Model;

// A record compares a list by reference, so two filters with the same rules compare here part by part.
public static class TableFilters
{
    public static bool Same(TableFilter? first, TableFilter? second)
    {
        if (first is null || second is null)
        {
            return first is null && second is null;
        }

        return first.Combinator == second.Combinator
            && string.Equals(first.RawSql, second.RawSql, StringComparison.Ordinal)
            && first.Rules.Count == second.Rules.Count
            && first.Rules.Zip(second.Rules).All(pair =>
                string.Equals(pair.First.Column, pair.Second.Column, StringComparison.Ordinal)
                && pair.First.Operator == pair.Second.Operator
                && SameValue(pair.First.Value, pair.Second.Value));
    }

    private static bool SameValue(FilterValue? first, FilterValue? second) => (first, second) switch
    {
        (FilterValue.List one, FilterValue.List other) => one.Values.SequenceEqual(other.Values, StringComparer.Ordinal),
        _ => first == second,
    };
}
