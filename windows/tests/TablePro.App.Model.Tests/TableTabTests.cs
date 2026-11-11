using TablePro.DataGrid.Model;
using TablePro.Interop;

namespace TablePro.App.Model.Tests;

public sealed class TableTabTests
{
    private readonly FakeSession _session = new() { TableRows = 3_503 };
    private readonly FakeTableView _view = new();
    private readonly FakeResults _results = new();
    private readonly TableTab _tab;
    private AppSettings _settings = new();

    public TableTabTests()
    {
        _tab = New();
    }

    [Fact]
    public async Task AFullFirstPageCountsTheTableAndPagesToItsLastAndToAPageInIt()
    {
        await _tab.RunAsync();

        Assert.Equal(1_000, _tab.Page.Rows);
        Assert.Equal(3_503, _tab.Page.Total);
        Assert.Equal(4, _tab.Page.Count);

        await _tab.LastPageAsync();

        Assert.Equal(3_000, _tab.Page.Offset);
        Assert.Equal(503, _tab.Page.Rows);

        await _tab.GoToPageAsync(2);
        await _tab.GoToPageAsync(9);
        await _tab.PreviousPageAsync();
        await _tab.NextPageAsync();
        await _tab.FirstPageAsync();

        Assert.Equal<long>([0, 3_000, 1_000, 0, 1_000, 0], _session.Queries.Select(query => query.Offset));
        Assert.Equal(1, _session.Counts);
    }

    [Fact]
    public async Task AFirstPageThatIsNotFullIsTheWholeTableWithNoCount()
    {
        _session.TableRows = 347;

        await _tab.RunAsync();

        Assert.Equal(347, _tab.Page.Total);
        Assert.Equal(0, _session.Counts);
        Assert.False(_tab.Page.IsPaged);
    }

    [Fact]
    public async Task ARefreshCountsTheTableAgain()
    {
        await _tab.RunAsync();
        _session.TableRows = 4_000;

        await _tab.RefreshAsync();

        Assert.Equal(2, _session.Counts);
        Assert.Equal(4_000, _tab.Page.Total);
    }

    [Fact]
    public async Task ANewPageSizeKeepsThePageHoldingTheFirstRowAndTheSnapshotKeepsBoth()
    {
        await _tab.RunAsync();
        await _tab.GoToPageAsync(3);

        await _tab.ResizeAsync(500);

        Assert.Equal(500, _tab.Page.Size);
        Assert.Equal(2_000, _tab.Page.Offset);
        Assert.Equal(500, _session.Queries[^1].Limit);
        var snapshot = _tab.Snapshot();
        Assert.Equal(500, snapshot.PageSize);
        Assert.Equal(2_000, snapshot.Offset);
        var restored = New(snapshot);
        Assert.Equal(500, restored.Page.Size);
        Assert.Equal(2_000, restored.Page.Offset);
    }

    [Fact]
    public async Task ADefaultPageSizeChangedInSettingsAppliesFromThePageShown()
    {
        await _tab.RunAsync();
        await _tab.GoToPageAsync(2);
        _settings = new AppSettings { PageSize = 500 };

        await _tab.RefreshAsync();

        Assert.Equal(500, _tab.Page.Size);
        Assert.Equal(1_000, _tab.Page.Offset);
        Assert.Null(_tab.Snapshot().PageSize);
    }

    [Fact]
    public async Task AllRowsAsksFirstAndShowsTheCountedTableOnOnePage()
    {
        await _tab.RunAsync();
        _view.ShowsAllRows = false;

        await _tab.ShowAllRowsAsync();

        Assert.Equal(1_000, _tab.Page.Size);

        _view.ShowsAllRows = true;
        await _tab.ShowAllRowsAsync();

        Assert.Equal(3_503, _tab.Page.Size);
        Assert.Equal(0, _tab.Page.Offset);
        Assert.Equal(3_503, _tab.Snapshot().PageSize);
    }

    [Fact]
    public void ARestoredTabStartsAtThePageHoldingItsFirstRow()
    {
        var tab = New(new SessionTab
        {
            Kind = TabKind.Table,
            Title = "Artist",
            Table = "Artist",
            PageSize = 20,
            Offset = 45,
        });

        Assert.Equal(40, tab.Page.Offset);
        Assert.Equal(20, tab.Page.Size);
        Assert.True(tab.Shows(null, "Artist"));
        Assert.False(tab.Shows("main", "Artist"));
    }

    [Fact]
    public async Task ASortReadsTheFirstPageInOrderAndARefusedOneKeepsTheShownSort()
    {
        await _tab.RunAsync();
        await _tab.NextPageAsync();
        var sort = new GridSort(1, SortDirection.Descending);

        await _tab.SortAsync(sort);

        var (sorted, _, offset) = _session.Queries[^1];
        Assert.Equal(new ColumnSort(1, false), sorted);
        Assert.Equal(0, offset);
        Assert.Equal(sort, _results.RunSort);

        _session.RefusesSort = true;
        await _tab.SortAsync(new GridSort(0, SortDirection.Ascending));

        Assert.Equal(sort, _results.Sort);
        Assert.Equal("error ffi.sort_unsupported", _results.Shown[^1]);
    }

    [Fact]
    public async Task EveryReloadMayGoWhileTheTabHasNothingOfItsOwnToLose()
    {
        Assert.False(_tab.HasUnsavedChanges);
        Assert.Equal(TransactionState.Idle, _tab.Transaction);
        foreach (var reason in Enum.GetValues<ReloadReason>())
        {
            Assert.True(await _tab.MayReloadAsync(reason));
        }
    }

    [Fact]
    public async Task ATableTabClosedWhileItsEditorOpensLetsItsSessionGoOnceAndShowsNothing()
    {
        var opening = new Gate();
        _session.Opening = opening;

        var loading = _tab.RunAsync();
        await opening.Reached;
        await _tab.CloseAsync();
        await loading;

        Assert.Empty(_session.Editors);
        Assert.Empty(_session.Queries);
        Assert.Equal(1, _session.Releases);
        Assert.Equal<string>(["clear"], _results.Shown);
    }

    [Fact]
    public async Task ATableTabClosedWhileItsPageIsWrittenDisposesItsEditorOnceAndRunsNothing()
    {
        var querying = new Gate(honorsCancel: false);
        _session.Querying = querying;

        var loading = _tab.RunAsync();
        await querying.Reached;
        var closing = _tab.CloseAsync();
        var waited = !closing.IsCompleted;
        querying.Open();
        await closing;
        await loading;

        Assert.True(waited);
        var editor = Assert.Single(_session.Editors);
        Assert.Equal(1, editor.Disposals);
        Assert.Empty(editor.Runs);
        Assert.Equal(1, _session.TableEditor.Disposals);
        Assert.Equal(1, _session.Releases);
        Assert.Equal<string>(["clear"], _results.Shown);
    }

    [Fact]
    public async Task ATableTabClosedWhileItsPageIsReadStopsTheRunAndCountsNothing()
    {
        var reading = new Gate();
        _session.PageReading = reading;

        var loading = _tab.RunAsync();
        await reading.Reached;
        await _tab.CloseAsync();
        await loading;

        var editor = Assert.Single(_session.Editors);
        var run = Assert.Single(editor.Started);
        Assert.Equal(1, run.Cancels);
        Assert.Equal(1, run.Disposals);
        Assert.Equal(1, editor.Disposals);
        Assert.Equal(1, _session.Releases);
        Assert.Equal(0, _session.Counts);
        Assert.Equal<string>(["run", "clear"], _results.Shown);
    }

    [Fact]
    public async Task ATableTabClosedWhileItCountsStopsTheCountAndLetsGoOnce()
    {
        var counting = new Gate();
        _session.Counting = counting;
        await _tab.RunAsync();
        await counting.Reached;
        var pagers = _view.Pagers.Count;

        await _tab.CloseAsync();

        Assert.Equal(1, Assert.Single(_session.Editors).Disposals);
        Assert.Equal(1, _session.Releases);
        Assert.Null(_tab.Page.Total);
        Assert.Equal(pagers, _view.Pagers.Count);
    }

    [Fact]
    public async Task ACountThatLandsAsTheTabClosesIsNotShown()
    {
        var counting = new Gate(honorsCancel: false);
        _session.Counting = counting;
        await _tab.RunAsync();
        var pagers = _view.Pagers.Count;

        var closing = _tab.CloseAsync();
        var waited = !closing.IsCompleted;
        counting.Open();
        await closing;

        Assert.True(waited);
        Assert.Null(_tab.Page.Total);
        Assert.Equal(pagers, _view.Pagers.Count);
        Assert.Equal(1, _session.Releases);
        Assert.Equal(1, Assert.Single(_session.Editors).Disposals);
    }

    [Fact]
    public async Task TheRowsShownGoWithTheClose()
    {
        var changes = 0;
        _tab.ShownRowsChanged += (_, _) => changes++;
        await _tab.RunAsync();

        await _tab.CloseAsync();
        await _tab.RunAsync();

        Assert.Equal(1, changes);
        Assert.Null(_tab.ShownRows);
        Assert.Single(_session.Queries);
    }

    private TableTab New(SessionTab? restore = null)
    {
        var tab = new TableTab(_session, _view, _results, new TableName(null, "Artist"), () => _settings, restore);
        _view.Tab = tab;
        return tab;
    }
}
