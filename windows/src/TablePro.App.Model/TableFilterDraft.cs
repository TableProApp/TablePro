using TablePro.Interop;

namespace TablePro.App.Model;

// How many values an operator takes, which decides the boxes a rule row shows.
public enum FilterValueShape
{
    None,
    One,
    Two,
    List,
}

public enum FilterProblemKind
{
    NoColumn,
    NoValue,
    NoSecondValue,
}

// The rule row that keeps the filter from being applied, and why; nothing is sent while one is left.
public sealed record FilterProblem(int Row, FilterProblemKind Kind);

// One rule row as typed. Value holds the bound from for Between and the comma-separated items for In and Not in.
public sealed class FilterDraftRule
{
    public string Column { get; set; } = string.Empty;

    public FilterOperator Operator { get; set; }

    public string Value { get; set; } = string.Empty;

    // The bound to of Between, kept while another operator is picked, as macOS keeps it.
    public string SecondValue { get; set; } = string.Empty;

    public FilterValueShape Shape => TableFilterDraft.ShapeOf(Operator);
}

// What the filter bar edits: rule rows, Match all or any, and the raw SQL row, over what the engine offers.
public sealed class TableFilterDraft
{
    private readonly List<FilterDraftRule> _rules = [];
    private readonly string[] _columns;

    public TableFilterDraft(FilterChoices choices)
    {
        ArgumentNullException.ThrowIfNull(choices);
        Choices = choices;
        _columns = [.. choices.Columns.Select(column => column.Name)];
    }

    public FilterChoices Choices { get; }

    public IReadOnlyList<string> Columns => _columns;

    public IReadOnlyList<FilterDraftRule> Rules => _rules;

    // Read as Match all where the engine has no OR.
    public bool MatchAny { get; set; }

    // Sent only where the engine takes a raw predicate; blank is no predicate.
    public string RawSql { get; set; } = string.Empty;

    public bool AcceptsRawSql => Choices.AcceptsRawSql;

    public bool OffersMatchAny => Choices.Combinators.Contains(FilterCombinator.Or);

    // All or any means something only once two clauses meet: two rules, or a rule and the SQL.
    public bool ShowsMatch => OffersMatchAny && (_rules.Count >= 2 || (_rules.Count == 1 && HasRawSql));

    public bool IsEmpty => _rules.Count == 0 && !HasRawSql;

    private bool HasRawSql => AcceptsRawSql && !string.IsNullOrWhiteSpace(RawSql);

    public static FilterValueShape ShapeOf(FilterOperator op) => op switch
    {
        FilterOperator.IsNull or FilterOperator.IsNotNull => FilterValueShape.None,
        FilterOperator.Between => FilterValueShape.Two,
        FilterOperator.In or FilterOperator.NotIn => FilterValueShape.List,
        _ => FilterValueShape.One,
    };

    // As macOS reads a list: split on commas, each item trimmed, blank items dropped.
    public static IReadOnlyList<string> SplitList(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        return [.. text.Split(',').Select(item => item.Trim()).Where(item => item.Length > 0)];
    }

    // A filter applied before, shown again as rows; a list shows its items joined as they are typed.
    public static TableFilterDraft From(TableFilter? filter, FilterChoices choices)
    {
        var draft = new TableFilterDraft(choices);
        if (filter is null)
        {
            return draft;
        }

        draft.MatchAny = filter.Combinator == FilterCombinator.Or;
        draft.RawSql = filter.RawSql ?? string.Empty;
        foreach (var rule in filter.Rules)
        {
            var row = new FilterDraftRule { Column = rule.Column, Operator = rule.Operator };
            switch (rule.Value)
            {
                case FilterValue.One single:
                    row.Value = single.Value;
                    break;
                case FilterValue.Pair pair:
                    row.Value = pair.Low;
                    row.SecondValue = pair.High;
                    break;
                case FilterValue.List list:
                    row.Value = string.Join(", ", list.Values);
                    break;
                default:
                    break;
            }

            draft._rules.Add(row);
        }

        return draft;
    }

    // Empty for a column the engine did not list.
    public IReadOnlyList<FilterOperator> OperatorsFor(string column)
    {
        ArgumentNullException.ThrowIfNull(column);
        return Choices.Columns.FirstOrDefault(choice => string.Equals(choice.Name, column, StringComparison.Ordinal))
            ?.Operators ?? [];
    }

    // On the first column and its first operator, as the Linux app adds a rule.
    public FilterDraftRule AddRule()
    {
        var first = Choices.Columns.Count > 0 ? Choices.Columns[0] : null;
        var rule = new FilterDraftRule
        {
            Column = first?.Name ?? string.Empty,
            Operator = first is { Operators.Count: > 0 } ? first.Operators[0] : FilterOperator.Equal,
        };
        _rules.Add(rule);
        return rule;
    }

    public void RemoveRule(FilterDraftRule rule)
    {
        ArgumentNullException.ThrowIfNull(rule);
        _rules.Remove(rule);
    }

    // The operator stays where the new column offers it, else the column's first is picked.
    public void SetColumn(FilterDraftRule rule, string column)
    {
        ArgumentNullException.ThrowIfNull(rule);
        ArgumentNullException.ThrowIfNull(column);
        rule.Column = column;
        var operators = OperatorsFor(column);
        if (operators.Count > 0 && !operators.Contains(rule.Operator))
        {
            rule.Operator = operators[0];
        }
    }

    public void Clear()
    {
        _rules.Clear();
        RawSql = string.Empty;
        MatchAny = false;
    }

    // Null with no rule and no SQL. A row missing its value is refused before anything is sent.
    public bool TryBuild(out TableFilter? filter, out FilterProblem? problem)
    {
        filter = null;
        problem = null;
        List<FilterRule> rules = [];
        for (var row = 0; row < _rules.Count; row++)
        {
            var rule = _rules[row];
            if (ProblemOf(rule) is { } kind)
            {
                problem = new FilterProblem(row, kind);
                return false;
            }

            rules.Add(new FilterRule(rule.Column, rule.Operator, ValueOf(rule)));
        }

        var raw = HasRawSql ? RawSql : null;
        if (rules.Count > 0 || raw is not null)
        {
            var combinator = MatchAny && OffersMatchAny ? FilterCombinator.Or : FilterCombinator.And;
            filter = new TableFilter(combinator, rules, raw);
        }

        return true;
    }

    // As macOS checks a row: a value of spaces is no value.
    private static FilterProblemKind? ProblemOf(FilterDraftRule rule)
    {
        if (string.IsNullOrWhiteSpace(rule.Column))
        {
            return FilterProblemKind.NoColumn;
        }

        return rule.Shape switch
        {
            FilterValueShape.One or FilterValueShape.Two when string.IsNullOrWhiteSpace(rule.Value) =>
                FilterProblemKind.NoValue,
            FilterValueShape.Two when string.IsNullOrWhiteSpace(rule.SecondValue) => FilterProblemKind.NoSecondValue,
            FilterValueShape.List when SplitList(rule.Value).Count == 0 => FilterProblemKind.NoValue,
            _ => null,
        };
    }

    // A value is sent as typed; the core reads it as the column's type and binds it.
    private static FilterValue? ValueOf(FilterDraftRule rule) => rule.Shape switch
    {
        FilterValueShape.None => null,
        FilterValueShape.One => new FilterValue.One(rule.Value),
        FilterValueShape.Two => new FilterValue.Pair(rule.Value, rule.SecondValue),
        _ => new FilterValue.List(SplitList(rule.Value)),
    };
}
