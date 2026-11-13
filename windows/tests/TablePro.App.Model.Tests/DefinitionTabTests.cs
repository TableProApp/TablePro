using TablePro.Interop;

namespace TablePro.App.Model.Tests;

public sealed class DefinitionTabTests
{
    private static readonly ObjectEntry Trigger = new("main", "Track_Audit", ObjectKind.Trigger, "Track");

    private readonly DefinitionSession _session = new();
    private readonly FakeDefinitionView _view = new();
    private readonly DefinitionTab _tab;

    public DefinitionTabTests()
    {
        _tab = new DefinitionTab(_session, _view, Trigger);
    }

    [Fact]
    public async Task ALoadShowsTheDefinitionAndRunsOnlyWhileItReads()
    {
        var reading = new Gate();
        _session.Reading = reading;
        var changes = 0;
        _tab.StateChanged += (_, _) => changes++;

        var loading = _tab.LoadAsync();
        await reading.Reached;
        var runningWhileRead = _tab.IsRunning;
        reading.Open();
        await loading;

        Assert.True(runningWhileRead);
        Assert.False(_tab.IsRunning);
        Assert.Equal(2, changes);
        Assert.Same(_session.Source, _tab.Source);
        Assert.Equal<string>(["loading", "source CREATE TRIGGER Track_Audit"], _view.Shown);
        Assert.Equal(Trigger, Assert.Single(_session.Reads));
    }

    [Fact]
    public async Task ADefinitionTabIsReadOnlyAndNamedForItsObject()
    {
        Assert.Equal("Track_Audit", _tab.Title);
        Assert.Equal(TabKind.Definition, _tab.Kind);
        Assert.Equal(TransactionState.Idle, _tab.Transaction);
        Assert.False(_tab.HasUnsavedChanges);
        Assert.True(await _tab.ConfirmCloseAsync(offerSave: true));
        Assert.Null(_tab.Source);
    }

    [Fact]
    public async Task AnObjectThatIsGoneOrCannotBeReadShowsUnavailableWithNoReason()
    {
        _session.Source = null;

        await _tab.LoadAsync();

        Assert.Null(_tab.Source);
        Assert.Equal<string>(["loading", "unavailable"], _view.Shown);
        Assert.False(_tab.IsRunning);
    }

    [Fact]
    public async Task AFailedReadSaysWhyAndAReloadReadsAgain()
    {
        _session.Failure = Errors.Of("ffi.not_connected");

        await _tab.LoadAsync();

        Assert.Null(_tab.Source);
        Assert.Equal<string>(["loading", "unavailable ffi.not_connected"], _view.Shown);

        _session.Failure = null;
        await _tab.LoadAsync();

        Assert.Same(_session.Source, _tab.Source);
        Assert.Equal("source CREATE TRIGGER Track_Audit", _view.Shown[^1]);
        Assert.Equal(2, _session.Reads.Count);
    }

    [Fact]
    public async Task AReloadAfterAFailureLeavesNothingOfTheSourceShownBefore()
    {
        await _tab.LoadAsync();
        _session.Failure = Errors.Of("ffi.not_connected");

        await _tab.LoadAsync();

        Assert.Null(_tab.Source);
        Assert.Equal("unavailable ffi.not_connected", _view.Shown[^1]);
    }

    [Fact]
    public async Task LoadsDuringAReadShareItAndALaterLoadReadsAgain()
    {
        var reading = new Gate();
        _session.Reading = reading;

        var first = _tab.LoadAsync();
        var second = _tab.LoadAsync();
        await reading.Reached;
        reading.Open();
        await Task.WhenAll(first, second);

        Assert.Single(_session.Reads);
        Assert.Equal<string>(["loading", "source CREATE TRIGGER Track_Audit"], _view.Shown);

        _session.Reading = null;
        await _tab.LoadAsync();

        Assert.Equal(2, _session.Reads.Count);
    }

    [Fact]
    public async Task ClosingDuringAReadStopsItShowsNothingAndLetsTheSessionGoOnce()
    {
        var reading = new Gate();
        _session.Reading = reading;
        var loading = _tab.LoadAsync();
        await reading.Reached;

        await Task.WhenAll(_tab.CloseAsync(), _tab.CloseAsync());
        await loading;
        await _tab.LoadAsync();

        Assert.Null(_tab.Source);
        Assert.False(_tab.IsRunning);
        Assert.Equal<string>(["loading"], _view.Shown);
        Assert.Single(_session.Reads);
        Assert.Equal(1, _session.Releases);
    }

    [Fact]
    public async Task ACloseWaitsForAReadThatDoesNotStopAndShowsNothingOfIt()
    {
        var reading = new Gate(honorsCancel: false);
        _session.Reading = reading;
        var loading = _tab.LoadAsync();
        await reading.Reached;

        var closing = _tab.CloseAsync();
        var waited = !closing.IsCompleted && _session.Releases == 0;
        reading.Open();
        await closing;
        await loading;

        Assert.True(waited);
        Assert.Null(_tab.Source);
        Assert.Equal<string>(["loading"], _view.Shown);
        Assert.Equal(1, _session.Releases);
    }

    [Fact]
    public void ASnapshotNamesTheObjectAndOpensItAgain()
    {
        var snapshot = _tab.Snapshot();

        Assert.Equal(
            new SessionTab
            {
                Kind = TabKind.Definition,
                Title = "Track_Audit",
                Schema = "main",
                Table = "Track_Audit",
                ObjectKind = "Trigger",
                ParentTable = "Track",
            },
            snapshot);
        Assert.Equal(Trigger, DefinitionTab.EntryOf(snapshot));
    }

    [Fact]
    public void ATabThatNamesNoObjectOrAKindThisBuildCannotReadIsNotRestored()
    {
        var saved = _tab.Snapshot();
        var sequence = new SessionTab { Kind = TabKind.Definition, Table = "next_id", ObjectKind = "Sequence" };

        Assert.Null(DefinitionTab.EntryOf(saved with { Kind = TabKind.Table }));
        Assert.Null(DefinitionTab.EntryOf(saved with { Table = null }));
        Assert.Null(DefinitionTab.EntryOf(saved with { Table = string.Empty }));
        Assert.Null(DefinitionTab.EntryOf(saved with { ObjectKind = "Hypertable" }));
        Assert.Null(DefinitionTab.EntryOf(saved with { ObjectKind = null }));
        Assert.Null(DefinitionTab.EntryOf(saved with { ObjectKind = "Key" }));
        Assert.Equal(new ObjectEntry(null, "next_id", ObjectKind.Sequence, null), DefinitionTab.EntryOf(sequence));
    }
}

internal sealed class FakeDefinitionView : IDefinitionTabView
{
    public List<string> Shown { get; } = [];

    public void ShowLoading() => Shown.Add("loading");

    public void ShowSource(ObjectSource source) => Shown.Add("source " + source.Sql);

    public void ShowUnavailable(CoreError? failure) =>
        Shown.Add(failure is null ? "unavailable" : "unavailable " + failure.Code);
}

// A definition tab reads only its object's definition, so any other call fails the test.
internal sealed class DefinitionSession : ITabSession
{
    public List<ObjectEntry> Reads { get; } = [];

    public ObjectSource? Source { get; set; } = new("CREATE TRIGGER Track_Audit", null, OpensInEditor: true);

    public CoreError? Failure { get; set; }

    public Gate? Reading { get; set; }

    public int Releases { get; private set; }

    public string Name => "Chinook";

    public string EngineId => "sqlite";

    public bool IsReadOnly => false;

    public async Task<ObjectSource?> GetObjectDefinitionAsync(ObjectEntry entry, CancellationToken cancellationToken)
    {
        Reads.Add(entry);
        if (Reading is { } reading)
        {
            await reading.PassAsync(cancellationToken);
        }

        return Failure is { } failure ? throw new TableProException(failure) : Source;
    }

    public ValueTask ReleaseAsync()
    {
        Releases++;
        return ValueTask.CompletedTask;
    }

    public Task<ITabEditor> OpenEditorAsync(CancellationToken cancellationToken) =>
        throw new NotSupportedException();

    public Task<TablePageRead> ReadTablePageAsync(
        TableName table,
        ColumnSort? sort,
        TableFilter? filter,
        long limit,
        long offset,
        CancellationToken cancellationToken) =>
        throw new NotSupportedException();

    public Task<long> CountRowsAsync(TableName table, TableFilter? filter, CancellationToken cancellationToken) =>
        throw new NotSupportedException();

    public Task<RowEstimate?> EstimateRowsAsync(TableName table, CancellationToken cancellationToken) =>
        throw new NotSupportedException();

    public Task<FilterChoices> GetFilterChoicesAsync(TableName table, CancellationToken cancellationToken) =>
        throw new NotSupportedException();

    public Task<TableStructure> GetStructureAsync(
        TableName table,
        ObjectKind kind,
        CancellationToken cancellationToken) =>
        throw new NotSupportedException();

    public RunGate GateRun(string sql) => throw new NotSupportedException();

    public Range? StatementAt(string sql, int caret) => throw new NotSupportedException();

    public string? SortedQuery(string sql, IReadOnlyList<string> columns, int column, bool ascending) =>
        throw new NotSupportedException();

    public Task<ITableEditor> OpenTableEditorAsync(
        TableName table,
        bool refresh,
        CancellationToken cancellationToken) =>
        throw new NotSupportedException();
}
