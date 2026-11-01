using TablePro.Core.Localization;
using TablePro.Core.Schema;

namespace TablePro.Core.Browse;

public readonly record struct SortColumn(string Column, bool Descending);

/// <summary>The operators the filter strip offers, the same set as the macOS app's browse filter.</summary>
public enum FilterOperator
{
    Equals,
    NotEquals,
    GreaterThan,
    GreaterOrEqual,
    LessThan,
    LessOrEqual,
    Contains,
    NotContains,
    StartsWith,
    EndsWith,
    IsNull,
    IsNotNull,
    IsEmpty,
    IsNotEmpty,
    In,
    NotIn,
    Between,
}

public static class FilterOperatorExtensions
{
    public static bool TakesValue(this FilterOperator op) =>
        op is not (FilterOperator.IsNull or FilterOperator.IsNotNull or FilterOperator.IsEmpty or FilterOperator.IsNotEmpty);

    public static string DisplayName(this FilterOperator op) => op switch
    {
        FilterOperator.Equals => "=",
        FilterOperator.NotEquals => "≠",
        FilterOperator.GreaterThan => ">",
        FilterOperator.GreaterOrEqual => "≥",
        FilterOperator.LessThan => "<",
        FilterOperator.LessOrEqual => "≤",
        FilterOperator.Contains => CoreStrings.Get("Browse/OperatorContains"),
        FilterOperator.NotContains => CoreStrings.Get("Browse/OperatorNotContains"),
        FilterOperator.StartsWith => CoreStrings.Get("Browse/OperatorStartsWith"),
        FilterOperator.EndsWith => CoreStrings.Get("Browse/OperatorEndsWith"),
        FilterOperator.IsNull => CoreStrings.Get("Browse/OperatorIsNull"),
        FilterOperator.IsNotNull => CoreStrings.Get("Browse/OperatorIsNotNull"),
        FilterOperator.IsEmpty => CoreStrings.Get("Browse/OperatorIsEmpty"),
        FilterOperator.IsNotEmpty => CoreStrings.Get("Browse/OperatorIsNotEmpty"),
        FilterOperator.In => CoreStrings.Get("Browse/OperatorIn"),
        FilterOperator.NotIn => CoreStrings.Get("Browse/OperatorNotIn"),
        FilterOperator.Between => CoreStrings.Get("Browse/OperatorBetween"),
        _ => op.ToString(),
    };
}

/// <summary>One condition of the filter strip. <see cref="Column"/> null searches every column.</summary>
public sealed record FilterRule(string? Column, FilterOperator Operator, string? Value = null, string? SecondValue = null, bool Enabled = true);

public sealed record BrowseFilter(IReadOnlyList<FilterRule> Rules, string? RawWhere = null, bool MatchAll = true)
{
    public static readonly BrowseFilter None = new([]);

    /// <summary>The columns an all-column search reaches. The driver fills it from the table's structure.</summary>
    public IReadOnlyList<string> SearchColumns { get; init; } = [];

    public bool IsEmpty => Rules.All(r => !r.Enabled) && string.IsNullOrWhiteSpace(RawWhere);
}

public sealed record BrowseRequest(ObjectName Table, BrowseFilter Filter, IReadOnlyList<SortColumn> Sort, int Offset, int Limit);
