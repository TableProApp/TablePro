using TablePro.Interop;

namespace TablePro.App.Model.Tests;

public sealed class CellFiltersTests
{
    private static readonly FilterOperator[] Ordered =
    [
        FilterOperator.Equal,
        FilterOperator.NotEqual,
        FilterOperator.Less,
        FilterOperator.Greater,
        FilterOperator.IsNull,
        FilterOperator.IsNotNull,
    ];

    private static readonly FilterOperator[] Textual =
        [FilterOperator.Equal, FilterOperator.NotEqual, FilterOperator.Contains, FilterOperator.IsNull, FilterOperator.IsNotNull];

    [Fact]
    public void AValueOffersEqualAndNotAndAnOrderedColumnGreaterAndLessToo()
    {
        var number = CellFilters.For("Total", Ordered, CellValue.Of("Total", "9.99"), "9.99", pending: false);
        var text = CellFilters.For("Name", Textual, CellValue.Of("Name", "AC/DC"), "AC/DC", pending: false);

        Assert.Equal<FilterOperator>(
            [FilterOperator.Equal, FilterOperator.NotEqual, FilterOperator.Greater, FilterOperator.Less],
            number.Select(rule => rule.Operator));
        Assert.All(number, rule => Assert.Equal(new FilterValue.One("9.99"), rule.Value));
        Assert.Equal<FilterOperator>([FilterOperator.Equal, FilterOperator.NotEqual], text.Select(rule => rule.Operator));
    }

    [Fact]
    public void ANullCellOffersTheNullTests()
    {
        var rules = CellFilters.For("Composer", Textual, CellValue.Of("Composer", null), null, pending: false);

        Assert.Equal<FilterOperator>([FilterOperator.IsNull, FilterOperator.IsNotNull], rules.Select(rule => rule.Operator));
        Assert.All(rules, rule => Assert.Null(rule.Value));
    }

    [Theory]
    [InlineData(" padded")]
    [InlineData("padded ")]
    [InlineData("null")]
    [InlineData("")]
    public void AValueAFilterRowWouldReadOtherwiseOffersNothing(string text) =>
        Assert.Empty(CellFilters.For("Name", Textual, CellValue.Of("Name", text), text, pending: false));

    [Fact]
    public void ABinaryValueALongValueAPendingEditAndAValueNoFilterBindsOfferNothing()
    {
        var bytes = new CellValue("Data", null, false, new byte[] { 1, 2 }, 2, IsDefault: false);
        var longText = CellValue.Of("Name", new string('x', CellFilters.MaximumValueLength + 1));

        Assert.Empty(CellFilters.For("Data", Textual, bytes, "0x0102", pending: false));
        Assert.Empty(CellFilters.For("Name", Textual, longText, longText.Text, pending: false));
        Assert.Empty(CellFilters.For("Name", Textual, CellValue.Of("Name", "typed"), "typed", pending: true));
        Assert.Empty(CellFilters.For("Name", Textual, null, null, pending: false));
        Assert.Empty(CellFilters.For("Active", Textual, CellValue.Of("Active", "true"), null, pending: false));
    }

    [Fact]
    public void ARuleJoinsMatchAllKeepingTheSqlAndRunsAloneUnderMatchAnyOfTwo()
    {
        var name = new FilterRule("Name", FilterOperator.Contains, new FilterValue.One("AC"));
        var id = new FilterRule("Id", FilterOperator.Greater, new FilterValue.One("3"));
        var added = new FilterRule("Name", FilterOperator.NotEqual, new FilterValue.One("AC/DC"));

        var all = CellFilters.With(new TableFilter(FilterCombinator.And, [name], "Id < 9"), added);
        var any = CellFilters.With(new TableFilter(FilterCombinator.Or, [name, id], null), added);
        var anyOfOne = CellFilters.With(new TableFilter(FilterCombinator.Or, [name], null), added);
        var none = CellFilters.With(null, added);

        Assert.Equal(new TableFilter(FilterCombinator.And, [name, added], "Id < 9").Rules, all.Rules);
        Assert.Equal("Id < 9", all.RawSql);
        Assert.Equal<FilterRule>([added], any.Rules);
        Assert.Equal(FilterCombinator.And, any.Combinator);
        Assert.Equal<FilterRule>([name, added], anyOfOne.Rules);
        Assert.Equal(FilterCombinator.And, anyOfOne.Combinator);
        Assert.Equal<FilterRule>([added], none.Rules);
    }

    [Fact]
    public void ARuleAlreadyRunningLeavesTheFilterAsItIs()
    {
        var name = new FilterRule("Name", FilterOperator.Equal, new FilterValue.One("AC/DC"));
        var running = new TableFilter(FilterCombinator.And, [name], null);

        Assert.Same(running, CellFilters.With(running, name with { }));
    }
}
