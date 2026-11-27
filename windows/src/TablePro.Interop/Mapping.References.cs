using Native = TablePro.Interop.Native;

namespace TablePro.Interop;

internal static partial class Mapping
{
    public static RowReferenceChoice Reference(Native.RowReferenceChoice choice) => new(
        checked((int)choice.Key),
        choice.Referencing,
        choice.KeyName,
        new TableName(choice.Table.Schema, choice.Table.Name),
        choice.Columns);

    public static FollowedReference Followed(Native.FollowedReference followed) => followed switch
    {
        Native.FollowedReference.Rows rows =>
            new FollowedReference.Rows(new TableName(rows.Table.Schema, rows.Table.Name), Filter(rows.Filter)),
        Native.FollowedReference.Refused { Refusal: var refusal } => refusal switch
        {
            Native.ReferenceRefusal.UnevenKey uneven => new FollowedReference.Refused(ReferenceRefusal.UnevenKey, uneven.Key),
            Native.ReferenceRefusal.UnknownSchema unknown =>
                new FollowedReference.Refused(ReferenceRefusal.UnknownSchema, unknown.Table),
            Native.ReferenceRefusal.NoFilterText text => new FollowedReference.Refused(ReferenceRefusal.NoFilterText, text.Column),
            Native.ReferenceRefusal.ComparedOtherwise otherwise =>
                new FollowedReference.Refused(ReferenceRefusal.ComparedOtherwise, otherwise.Table),
            _ => throw new InvalidOperationException("The core sent a refusal this build does not know."),
        },
        _ => throw new InvalidOperationException("The core sent a reference this build does not know."),
    };

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
