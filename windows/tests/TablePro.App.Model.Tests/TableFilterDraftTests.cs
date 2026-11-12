using TablePro.Interop;

namespace TablePro.App.Model.Tests;

public sealed class TableFilterDraftTests
{
    // ArtistId and Name, with AND, OR and raw SQL.
    private readonly FilterChoices _choices = new FakeSession().Choices;

    [Theory]
    [InlineData(FilterOperator.IsNull, FilterValueShape.None)]
    [InlineData(FilterOperator.IsNotNull, FilterValueShape.None)]
    [InlineData(FilterOperator.Between, FilterValueShape.Two)]
    [InlineData(FilterOperator.In, FilterValueShape.List)]
    [InlineData(FilterOperator.NotIn, FilterValueShape.List)]
    [InlineData(FilterOperator.Equal, FilterValueShape.One)]
    [InlineData(FilterOperator.NotEqual, FilterValueShape.One)]
    [InlineData(FilterOperator.Less, FilterValueShape.One)]
    [InlineData(FilterOperator.LessOrEqual, FilterValueShape.One)]
    [InlineData(FilterOperator.Greater, FilterValueShape.One)]
    [InlineData(FilterOperator.GreaterOrEqual, FilterValueShape.One)]
    [InlineData(FilterOperator.Contains, FilterValueShape.One)]
    [InlineData(FilterOperator.StartsWith, FilterValueShape.One)]
    [InlineData(FilterOperator.EndsWith, FilterValueShape.One)]
    [InlineData(FilterOperator.Like, FilterValueShape.One)]
    [InlineData(FilterOperator.NotLike, FilterValueShape.One)]
    [InlineData(FilterOperator.ILike, FilterValueShape.One)]
    public void EachOperatorTakesTheValuesItComparesWith(FilterOperator op, FilterValueShape shape)
    {
        var draft = new TableFilterDraft(_choices);
        var rule = draft.AddRule();
        rule.Operator = op;
        rule.Value = "1";
        rule.SecondValue = "9";

        Assert.Equal(shape, TableFilterDraft.ShapeOf(op));
        Assert.Equal(shape, rule.Shape);
        Assert.True(draft.TryBuild(out var filter, out var problem));
        Assert.Null(problem);
        var expected = shape switch
        {
            FilterValueShape.None => "-",
            FilterValueShape.One => "1",
            FilterValueShape.Two => "1..9",
            _ => "[1]",
        };
        Assert.Equal($"And: ArtistId {op} {expected} | ", FilterText.Of(filter));
    }

    [Fact]
    public void AListIsSplitOnCommasWithEachItemTrimmedAndBlankOnesDropped()
    {
        Assert.Equal<string>(["a", "b", "c d"], TableFilterDraft.SplitList(" a, ,b ,c d,"));
        Assert.Empty(TableFilterDraft.SplitList(" , "));
    }

    [Fact]
    public void ARowMissingItsValueIsRefusedBeforeAnythingIsSent()
    {
        var draft = new TableFilterDraft(_choices);
        var equal = draft.AddRule();
        var between = draft.AddRule();
        between.Operator = FilterOperator.Between;
        between.Value = "1";
        var list = draft.AddRule();
        list.Operator = FilterOperator.In;
        list.Value = " , ";
        var none = draft.AddRule();
        none.Operator = FilterOperator.IsNull;

        Assert.False(draft.TryBuild(out var filter, out var problem));
        Assert.Null(filter);
        Assert.Equal(new FilterProblem(0, FilterProblemKind.NoValue), problem);

        equal.Value = "   ";
        Assert.Equal(new FilterProblem(0, FilterProblemKind.NoValue), Problem(draft));

        equal.Value = "7";
        Assert.Equal(new FilterProblem(1, FilterProblemKind.NoSecondValue), Problem(draft));

        between.SecondValue = "9";
        Assert.Equal(new FilterProblem(2, FilterProblemKind.NoValue), Problem(draft));

        list.Value = "1, 2";
        Assert.True(draft.TryBuild(out filter, out problem));
        Assert.Null(problem);
        const string Built = "And: ArtistId Equal 7; ArtistId Between 1..9; ArtistId In [1, 2]; ArtistId IsNull - | ";
        Assert.Equal(Built, FilterText.Of(filter));
    }

    [Fact]
    public void ARowWithNoColumnIsRefused()
    {
        var draft = new TableFilterDraft(new FilterChoices([], [FilterCombinator.And], AcceptsRawSql: false));
        var rule = draft.AddRule();
        rule.Value = "1";

        Assert.Equal(string.Empty, rule.Column);
        Assert.Equal(new FilterProblem(0, FilterProblemKind.NoColumn), Problem(draft));
    }

    [Fact]
    public void ADraftWithNoRuleAndNoSqlIsNoFilter()
    {
        var draft = new TableFilterDraft(_choices) { RawSql = "  ", MatchAny = true };

        Assert.True(draft.IsEmpty);
        Assert.True(draft.TryBuild(out var filter, out var problem));
        Assert.Null(filter);
        Assert.Null(problem);
    }

    [Fact]
    public void RawSqlAndMatchAnyGoOnlyToAnEngineThatTakesThem()
    {
        var plain = new FilterChoices(_choices.Columns, [FilterCombinator.And], AcceptsRawSql: false);
        var draft = new TableFilterDraft(plain) { RawSql = "length(Name) > 3", MatchAny = true };
        draft.AddRule().Value = "1";
        draft.AddRule().Value = "2";

        Assert.False(draft.AcceptsRawSql);
        Assert.False(draft.OffersMatchAny);
        Assert.False(draft.ShowsMatch);
        Assert.True(draft.TryBuild(out var filter, out _));
        Assert.Equal("And: ArtistId Equal 1; ArtistId Equal 2 | ", FilterText.Of(filter));

        var sqlOnly = new TableFilterDraft(_choices) { RawSql = "length(Name) > 3", MatchAny = true };

        Assert.True(sqlOnly.TryBuild(out filter, out _));
        Assert.Equal("Or:  | length(Name) > 3", FilterText.Of(filter));
    }

    [Fact]
    public void MatchAllOrAnyShowsOnceTwoClausesMeet()
    {
        var draft = new TableFilterDraft(_choices);
        draft.AddRule();

        Assert.False(draft.ShowsMatch);

        draft.RawSql = "length(Name) > 3";
        Assert.True(draft.ShowsMatch);

        draft.RawSql = string.Empty;
        draft.AddRule();
        Assert.True(draft.ShowsMatch);

        draft.Clear();
        Assert.True(draft.IsEmpty);
        Assert.False(draft.MatchAny);
    }

    [Fact]
    public void ANewRuleStartsOnTheFirstColumnAndAnotherColumnKeepsTheOperatorWhereItIsOffered()
    {
        var draft = new TableFilterDraft(_choices);
        var rule = draft.AddRule();

        Assert.Equal<string>(["ArtistId", "Name"], draft.Columns);
        Assert.Equal("ArtistId", rule.Column);
        Assert.Equal(FilterOperator.Equal, rule.Operator);

        rule.Operator = FilterOperator.In;
        draft.SetColumn(rule, "Name");

        Assert.Equal(FilterOperator.In, rule.Operator);

        rule.Operator = FilterOperator.IsNotNull;
        draft.SetColumn(rule, "ArtistId");

        Assert.Equal("ArtistId", rule.Column);
        Assert.Equal(FilterOperator.Equal, rule.Operator);
        Assert.Contains(FilterOperator.Between, draft.OperatorsFor("ArtistId"));
        Assert.Empty(draft.OperatorsFor("Gone"));

        draft.RemoveRule(rule);

        Assert.Empty(draft.Rules);
    }

    [Fact]
    public void AnAppliedFilterShowsAgainAsItWasTypedAndBuildsTheSameFilter()
    {
        var filter = new TableFilter(
            FilterCombinator.Or,
            [
                new FilterRule("ArtistId", FilterOperator.Between, new FilterValue.Pair("1", "9")),
                new FilterRule("Name", FilterOperator.In, new FilterValue.List(["AC/DC", "Accept"])),
                new FilterRule("Name", FilterOperator.IsNotNull, null),
                new FilterRule("Name", FilterOperator.Contains, new FilterValue.One(" AC ")),
            ],
            "length(Name) > 3");

        var draft = TableFilterDraft.From(filter, _choices);

        Assert.True(draft.MatchAny);
        Assert.Equal("length(Name) > 3", draft.RawSql);
        Assert.Equal(("1", "9"), (draft.Rules[0].Value, draft.Rules[0].SecondValue));
        Assert.Equal("AC/DC, Accept", draft.Rules[1].Value);
        Assert.Equal(string.Empty, draft.Rules[2].Value);
        Assert.True(draft.TryBuild(out var rebuilt, out var problem));
        Assert.Null(problem);
        Assert.Equal(FilterText.Of(filter), FilterText.Of(rebuilt));
        Assert.True(TableFilterDraft.From(null, _choices).IsEmpty);
    }

    private static FilterProblem? Problem(TableFilterDraft draft) =>
        draft.TryBuild(out _, out var problem) ? null : problem;
}
