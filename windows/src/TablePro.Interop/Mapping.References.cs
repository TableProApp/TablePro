using Native = TablePro.Interop.Native;

namespace TablePro.Interop;

internal static partial class Mapping
{
    public static RowReferenceChoice Reference(Native.RowReferenceChoice choice)
    {
        var (refusal, subject) = choice.Refusal switch
        {
            Native.ReferenceRefusal.UnevenKey uneven => (ReferenceRefusal.UnevenKey, uneven.Key),
            Native.ReferenceRefusal.UnknownSchema unknown => (ReferenceRefusal.UnknownSchema, unknown.Table),
            Native.ReferenceRefusal.NoFilterText text => (ReferenceRefusal.NoFilterText, text.Column),
            Native.ReferenceRefusal.ComparedOtherwise otherwise => (ReferenceRefusal.ComparedOtherwise, otherwise.Table),
            _ => ((ReferenceRefusal?)null, (string?)null),
        };
        return new RowReferenceChoice(
            choice.KeyName,
            new TableName(choice.Table.Schema, choice.Table.Name),
            choice.Columns,
            choice.Filter is { } filter ? Filter(filter) : null,
            refusal,
            subject);
    }

    private static TableFilter Filter(Native.TableFilterArg filter) => new(
        filter.Combinator == Native.CombinatorTag.Or ? FilterCombinator.Or : FilterCombinator.And,
        [.. filter.Rules.Select(rule => new FilterRule(rule.Column, Operator(rule.Op), Value(rule.Value)))],
        filter.RawSql);

    private static FilterValue? Value(Native.FilterValueArg? value) => value switch
    {
        Native.FilterValueArg.Single single => new FilterValue.One(single.Value),
        Native.FilterValueArg.Pair pair => new FilterValue.Pair(pair.Low, pair.High),
        Native.FilterValueArg.List list => new FilterValue.List(list.Values),
        _ => null,
    };
}
