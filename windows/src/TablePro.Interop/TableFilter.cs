namespace TablePro.Interop;

// Contains, StartsWith and EndsWith match the text as typed; Like and NotLike keep the user's own wildcards.
public enum FilterOperator
{
    Equal,
    NotEqual,
    Less,
    LessOrEqual,
    Greater,
    GreaterOrEqual,
    Contains,
    StartsWith,
    EndsWith,
    Like,
    NotLike,
    ILike,
    IsNull,
    IsNotNull,
    In,
    NotIn,
    Between,
}

public enum FilterCombinator
{
    And,
    Or,
}

// Text as typed. The core parses it as the column's type and binds it, so it never becomes SQL.
public abstract record FilterValue
{
    private FilterValue()
    {
    }

    public sealed record One(string Value) : FilterValue;

    // For Between.
    public sealed record Pair(string Low, string High) : FilterValue;

    // For In and NotIn.
    public sealed record List(IReadOnlyList<string> Values) : FilterValue;
}

// Value: null for IsNull and IsNotNull.
public sealed record FilterRule(string Column, FilterOperator Operator, FilterValue? Value);

// RawSql joins the rules as written, so the core refuses it unless it reads as exactly one expression.
public sealed record TableFilter(FilterCombinator Combinator, IReadOnlyList<FilterRule> Rules, string? RawSql);

public sealed record FilterColumn(string Name, IReadOnlyList<FilterOperator> Operators);

// AcceptsRawSql: false for an engine whose typed filter is not SQL, such as a document engine's query document.
public sealed record FilterChoices(
    IReadOnlyList<FilterColumn> Columns,
    IReadOnlyList<FilterCombinator> Combinators,
    bool AcceptsRawSql);
