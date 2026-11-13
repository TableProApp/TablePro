using TablePro.DataGrid.Model;
using TablePro.Interop;

namespace TablePro.App.Model.Tests;

public sealed class TableShareTests
{
    private static readonly TableFilter ByName = new(
        FilterCombinator.And,
        [new FilterRule("Name", FilterOperator.Contains, new FilterValue.One("AC"))],
        null);

    private readonly FakeSession _session = new() { TableRows = 3_503, FilteredRows = 1_200 };
    private readonly TableTab _tab;

    public TableShareTests()
    {
        _tab = new TableTab(
            _session,
            new FakeTableView(),
            new FakeResults(),
            new TableName(null, "Artist"),
            ObjectKind.Table,
            () => new AppSettings());
    }

    [Fact]
    public async Task AShareReadsTheViewFromItsFirstRowWithTheShownFilterAndSortWhicheverPageShows()
    {
        await _tab.RunAsync();
        await _tab.ApplyFilterAsync(ByName);
        await _tab.SortAsync(new GridSort(1, SortDirection.Descending));
        await _tab.NextPageAsync();
        var shown = _tab.Page.Offset;

        using var read = await _tab.ReadForShareAsync(10_000, TestContext.Current.CancellationToken);

        Assert.Equal(1_000, shown);
        Assert.Equal<(ColumnSort?, long, long)>((new ColumnSort(1, false), 10_000, 0), _session.Queries[^1]);
        Assert.Same(ByName, _session.PageFilters[^1]);
        Assert.Same(ByName, _session.CountFilters[^1]);
        Assert.Equal(1_200, read.TotalRows);
        Assert.Equal(2, read.VisibleColumns);
        Assert.Equal("SELECT * FROM \"Artist\"", read.ViewSql);
        Assert.Equal(1_000, _tab.Page.Offset);
    }

    [Fact]
    public async Task AnEngineWithNoViewSqlStillSharesItsRowsAndCount()
    {
        _session.ViewSql = null;
        await _tab.RunAsync();

        using var read = await _tab.ReadForShareAsync(1_000, TestContext.Current.CancellationToken);

        Assert.Null(read.ViewSql);
        Assert.Equal(3_503, read.TotalRows);
        Assert.Equal<(ColumnSort?, long, long)>((null, 1_000, 0), _session.Queries[^1]);
    }

    [Fact]
    public async Task AReadTheServerRefusesThrowsItsErrorAndLetsTheRunGo()
    {
        await _tab.RunAsync();
        await _tab.ApplyFilterAsync(ByName);
        _session.FilteredReadEnds = new QueryOutcome.Failed(Errors.Of("driver.server"));
        var counts = _session.Counts;

        var refused = await Assert.ThrowsAsync<TableProException>(
            () => _tab.ReadForShareAsync(1_000, TestContext.Current.CancellationToken));

        Assert.Equal("driver.server", refused.Code);
        Assert.Equal(1, _session.Pages[^1].Disposals);
        Assert.Equal(counts, _session.Counts);
    }

    [Fact]
    public async Task AStoppedReadIsACancel()
    {
        await _tab.RunAsync();
        await _tab.ApplyFilterAsync(ByName);
        _session.FilteredReadEnds = new QueryOutcome.Cancelled();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(
            () => _tab.ReadForShareAsync(1_000, TestContext.Current.CancellationToken));
    }

    [Fact]
    public async Task ClosingTheSheetStopsTheReadAndCountsNothing()
    {
        await _tab.RunAsync();
        var counts = _session.Counts;
        var querying = new Gate();
        _session.Querying = querying;
        using var closing = new CancellationTokenSource();

        var reading = _tab.ReadForShareAsync(1_000, closing.Token);
        await querying.Reached;
        await closing.CancelAsync();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => reading);
        Assert.Equal(counts, _session.Counts);
    }
}
