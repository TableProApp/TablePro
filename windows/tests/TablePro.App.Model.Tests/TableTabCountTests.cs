using TablePro.Interop;

namespace TablePro.App.Model.Tests;

public sealed class TableTabCountTests
{
    private static readonly TableFilter ByName = new(
        FilterCombinator.And,
        [new FilterRule("Name", FilterOperator.Contains, new FilterValue.One("AC"))],
        null);

    private readonly FakeSession _session = new() { TableRows = 2_000_123, FilteredRows = 1_200 };
    private readonly FakeTableView _view = new();
    private readonly FakeResults _results = new();
    private AppSettings _settings = new();

    [Fact]
    public async Task AnEstimateOfTwoMillionRowsShowsWithNoCountAndLeavesLastAndGoToPageOff()
    {
        _session.Estimate = new RowEstimate(2_000_000, IsExact: false);
        var tab = New();

        await tab.RunAsync();

        Assert.Equal(0, _session.Counts);
        Assert.Equal(2_000_000, tab.Page.Estimate);
        Assert.Null(tab.Page.Total);
        Assert.Null(tab.Page.Count);
        Assert.True(tab.Page.HasNext);
        Assert.False(tab.Page.HasLast);
        Assert.False(tab.Page.Accepts(2));
        Assert.True(tab.OffersCount);
        Assert.True(tab.CanCountRows);

        await tab.ShowAllRowsAsync();
        await tab.NextPageAsync();

        Assert.Equal(1_000, tab.Page.Size);
        Assert.Equal(1_000, tab.Page.Offset);
        Assert.Equal(2_000_000, tab.Page.Estimate);
        Assert.Equal(1, _session.Estimates);
        Assert.Equal(0, _session.Counts);
    }

    [Theory]
    [InlineData(50_000L, 1)]
    [InlineData(99_999L, 1)]
    [InlineData(100_000L, 0)]
    [InlineData(2_000_000L, 0)]
    public async Task TheServerCountsByItselfOnlyATableEstimatedUnderAHundredThousandRows(long estimate, int counts)
    {
        _session.Estimate = new RowEstimate(estimate, IsExact: false);
        var tab = New();

        await tab.RunAsync();

        long? total = counts == 1 ? 2_000_123 : null;
        Assert.Equal(counts, _session.Counts);
        Assert.Equal(total, tab.Page.Total);
        Assert.Equal(estimate, tab.Page.Estimate);
    }

    [Fact]
    public async Task AnExactEstimateOfTheWholeTableIsItsTotalWithNoCount()
    {
        _settings = new AppSettings { PageSize = 5 };
        _session.TableRows = 7;
        _session.Estimate = new RowEstimate(7, IsExact: true);
        var tab = New();

        await tab.RunAsync();

        Assert.Equal(0, _session.Counts);
        Assert.Equal(7, tab.Page.Total);
        Assert.Equal(2, tab.Page.Count);
        Assert.True(tab.Page.HasLast);
        Assert.False(tab.OffersCount);
    }

    [Fact]
    public async Task UnderAFilterTheTablesEstimateOfTwoMillionCountsNothingAndShowsNoTotal()
    {
        _session.Estimate = new RowEstimate(2_000_000, IsExact: false);
        var tab = New();
        await tab.RunAsync();

        await tab.ApplyFilterAsync(ByName);

        Assert.Equal(2, _session.Estimates);
        Assert.Equal(0, _session.Counts);
        Assert.Null(tab.Page.Total);
        Assert.Null(tab.Page.Estimate);
        Assert.True(tab.OffersCount);
    }

    [Fact]
    public async Task WithNoEstimateTheServerCountsAsBefore()
    {
        var tab = New();

        await tab.RunAsync();

        Assert.Equal(1, _session.Estimates);
        Assert.Equal(1, _session.Counts);
        Assert.Equal(2_000_123, tab.Page.Total);
        Assert.Null(tab.Page.Estimate);
    }

    [Fact]
    public async Task AnEstimateThatFailsLeavesTheCountToTheServer()
    {
        _session.EstimateFailure = Errors.Of("operation.timeout");
        var tab = New();

        await tab.RunAsync();

        Assert.Equal(1, _session.Estimates);
        Assert.Equal(1, _session.Counts);
        Assert.Equal(2_000_123, tab.Page.Total);
    }

    [Fact]
    public async Task CountRowsCountsTheTableTheEstimateHeldBack()
    {
        _session.Estimate = new RowEstimate(2_000_000, IsExact: false);
        var tab = New();
        await tab.RunAsync();

        await tab.CountRowsAsync();

        Assert.Equal(1, _session.Estimates);
        Assert.Equal(1, _session.Counts);
        Assert.Equal(2_000_123, tab.Page.Total);
        Assert.True(tab.Page.HasLast);
        Assert.False(tab.OffersCount);
        Assert.False(tab.IsCounting);
    }

    // MySQL keeps TABLE_ROWS for a day and an unanalysed table can read 0, so an estimate under the rows read is no total.
    [Theory]
    [InlineData(0L, null)]
    [InlineData(1_000L, null)]
    [InlineData(1_001L, 1_001L)]
    public void AnEstimateShowsOnlyWhenItIsMoreThanTheRowsShown(long estimate, long? shown)
    {
        var page = TablePage.First(1_000) with { Rows = 1_000, Estimate = estimate };

        Assert.Equal(shown, page.ShownEstimate);
    }

    [Fact]
    public async Task APageTurnLeavesTheCountTheUserAskedForRunning()
    {
        // No estimate, and the count the tab ran by itself timed out, so Count rows is offered.
        _session.CountFailure = Errors.Of("operation.timeout");
        var tab = New();
        await tab.RunAsync();
        Assert.True(tab.CanCountRows);
        _session.CountFailure = null;

        var asked = new Gate();
        _session.Counting = asked;
        var count = tab.CountRowsAsync();
        await asked.Reached;
        await tab.NextPageAsync();

        Assert.True(tab.IsCounting);
        asked.Open();
        await count;

        Assert.Equal(2, _session.Counts);
        Assert.Equal(2_000_123, tab.Page.Total);
        Assert.Equal(1_000, tab.Page.Offset);
    }

    [Fact]
    public async Task AnEstimateThatLandsAsTheTabClosesShowsNothingAndCountsNothing()
    {
        var estimating = new Gate(honorsCancel: false);
        _session.Estimating = estimating;
        _session.Estimate = new RowEstimate(2_000_000, IsExact: false);
        var tab = New();
        await tab.RunAsync();
        await estimating.Reached;
        var pagers = _view.Pagers.Count;

        var closing = tab.CloseAsync();
        var waited = !closing.IsCompleted;
        estimating.Open();
        await closing;

        Assert.True(waited);
        Assert.Null(tab.Page.Estimate);
        Assert.Null(tab.Page.Total);
        Assert.Equal(0, _session.Counts);
        Assert.Equal(pagers, _view.Pagers.Count);
        Assert.Equal(1, _session.Releases);
    }

    private TableTab New()
    {
        var tab = new TableTab(
            _session,
            _view,
            _results,
            new TableName(null, "Artist"),
            ObjectKind.Table,
            () => _settings,
            null);
        _view.Tab = tab;
        return tab;
    }
}
