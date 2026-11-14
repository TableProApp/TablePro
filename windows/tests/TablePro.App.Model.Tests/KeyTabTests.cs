using TablePro.Interop;

namespace TablePro.App.Model.Tests;

public sealed class KeyTabTests
{
    private static readonly KeyWindow FirstFields = new(
        KeyKind.Hash, "hash", new KeyTtl.ExpiresIn(TimeSpan.FromSeconds(3_780)), 1_200, 500, true, false, false);

    private static readonly KeyWindow MoreFields = FirstFields with { Rows = 1_000 };

    private static readonly KeyWindow LastFields = FirstFields with { Rows = 1_200, HasMore = false };

    private readonly FakeSession _session = new();
    private readonly FakeKeyServer _server = new();
    private readonly FakeKeyView _view = new();
    private readonly KeyTab _tab;

    public KeyTabTests()
    {
        _tab = new KeyTab(_session, _view, "user:42", _server.Open);
    }

    [Fact]
    public async Task TheFirstWindowShowsTheTypeLengthAndExpiryOverItsRows()
    {
        _server.Windows = [FirstFields, LastFields];
        var reading = new Gate();
        _server.Reading = reading;
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
        Assert.Equal<string>(["reading", "rows", "window Hash 500 of 1200, 3780 s"], _view.Shown);
        Assert.Same(FirstFields, _tab.Window);
        Assert.True(_tab.CanLoadMore);
        Assert.False(_tab.IsMissing);
        var reader = Assert.Single(_server.Readers);
        Assert.Equal((1, 1), (reader.Reads, reader.RowsAsked));
    }

    [Fact]
    public async Task LoadMoreReadsTheNextWindowIntoTheRowsShown()
    {
        _server.Windows = [FirstFields, MoreFields, LastFields];
        await _tab.LoadAsync();

        await _tab.LoadMoreAsync();

        Assert.Equal<string>(
            ["reading", "rows", "window Hash 500 of 1200, 3780 s", "reading", "window Hash 1000 of 1200, 3780 s"],
            _view.Shown);
        var reader = Assert.Single(_server.Readers);
        Assert.Equal((2, 1), (reader.Reads, reader.RowsAsked));
        Assert.Same(MoreFields, _tab.Window);
        Assert.True(_tab.CanLoadMore);
    }

    [Fact]
    public async Task ThereIsNoLoadMorePastTheLastWindow()
    {
        _server.Windows = [FirstFields, LastFields];
        await _tab.LoadAsync();
        await _tab.LoadMoreAsync();

        Assert.False(_tab.CanLoadMore);
        await _tab.LoadMoreAsync();

        Assert.Equal(2, Assert.Single(_server.Readers).Reads);
        Assert.Equal("window Hash 1200 of 1200, 3780 s", _view.Shown[^1]);
        Assert.Equal(5, _view.Shown.Count);
    }

    [Fact]
    public async Task AKeyThatDoesNotExistSaysSo()
    {
        await _tab.LoadAsync();

        Assert.Equal<string>(["reading", "missing"], _view.Shown);
        Assert.True(_tab.IsMissing);
        Assert.Null(_tab.Window);
        Assert.False(_tab.CanLoadMore);
        Assert.Equal(0, Assert.Single(_server.Readers).RowsAsked);
    }

    [Fact]
    public async Task AKeyDeletedBetweenWindowsLetsGoOfItsRowsAndSaysSo()
    {
        _server.Windows = [FirstFields, null];
        await _tab.LoadAsync();

        await _tab.LoadMoreAsync();

        Assert.Equal<string>(["reading", "released", "missing"], _view.Shown.Skip(3));
        Assert.True(_tab.IsMissing);
        Assert.False(_tab.CanLoadMore);

        _server.Windows = [LastFields];
        await _tab.LoadAsync();

        Assert.False(_tab.IsMissing);
        Assert.Equal<string>(["reading", "rows", "window Hash 1200 of 1200, 3780 s"], _view.Shown.Skip(6));
    }

    [Fact]
    public async Task AFailedLoadMoreKeepsTheRowsShownAndCanBeTriedAgain()
    {
        _server.Windows = [FirstFields, LastFields];
        await _tab.LoadAsync();
        _server.Failure = Errors.Of("ffi.not_connected");

        await _tab.LoadMoreAsync();

        Assert.Equal<string>(["reading", "failed ffi.not_connected"], _view.Shown.Skip(3));
        Assert.DoesNotContain("released", _view.Shown);
        Assert.Same(FirstFields, _tab.Window);
        Assert.True(_tab.CanLoadMore);

        _server.Failure = null;
        await _tab.LoadMoreAsync();

        Assert.Equal("window Hash 1200 of 1200, 3780 s", _view.Shown[^1]);
        Assert.Single(_view.Shown, shown => shown == "rows");
    }

    [Fact]
    public async Task AFailedRefreshKeepsTheRowsShownAndOnlyRefreshReadsAgain()
    {
        _server.Windows = [FirstFields, LastFields];
        await _tab.LoadAsync();
        _server.Failure = Errors.Of("ffi.not_connected");

        await _tab.LoadAsync();

        Assert.Equal<string>(["reading", "failed ffi.not_connected"], _view.Shown.Skip(3));
        Assert.Same(FirstFields, _tab.Window);
        Assert.False(_tab.CanLoadMore);
        await _tab.LoadMoreAsync();
        Assert.Equal(2, _server.Readers.Count);

        _server.Failure = null;
        await _tab.LoadAsync();

        Assert.Equal<string>(["reading", "rows", "window Hash 500 of 1200, 3780 s"], _view.Shown.Skip(5));
        Assert.Equal<int>([1, 1, 0], _server.Readers.Select(reader => reader.Disposals));
    }

    [Fact]
    public async Task RefreshReadsFromTheStartWithANewReader()
    {
        _server.Windows = [FirstFields, MoreFields];
        await _tab.LoadAsync();
        await _tab.LoadMoreAsync();

        await _tab.LoadAsync();

        Assert.Equal(2, _server.Readers.Count);
        Assert.Equal<int>([1, 0], _server.Readers.Select(reader => reader.Disposals));
        Assert.Equal((1, 1), (_server.Readers[1].Reads, _server.Readers[1].RowsAsked));
        Assert.Equal<string>(["reading", "rows", "window Hash 500 of 1200, 3780 s"], _view.Shown.Skip(5));
        Assert.Same(FirstFields, _tab.Window);
    }

    [Fact]
    public async Task AKeyThatChangedTypeShowsItsNewRows()
    {
        var list = new KeyWindow(KeyKind.List, "list", KeyTtl.Persistent.Instance, 3, 3, false, false, true);
        _server.Windows = [FirstFields, list];
        await _tab.LoadAsync();

        await _tab.LoadMoreAsync();

        Assert.Equal<string>(["reading", "rows", "window List 3 of 3, none"], _view.Shown.Skip(3));
        Assert.Equal(2, Assert.Single(_server.Readers).RowsAsked);
        Assert.Same(list, _tab.Window);
        Assert.False(_tab.CanLoadMore);
    }

    [Fact]
    public async Task StopEndsTheReadAndKeepsTheRowsShown()
    {
        _server.Windows = [FirstFields, LastFields];
        await _tab.LoadAsync();
        var reading = new Gate();
        _server.Reading = reading;
        var loading = _tab.LoadMoreAsync();
        await reading.Reached;

        _tab.Stop();
        await loading;

        Assert.Equal<string>(["reading", "stopped"], _view.Shown.Skip(3));
        Assert.Same(FirstFields, _tab.Window);
        Assert.False(_tab.IsRunning);
        Assert.True(_tab.CanLoadMore);
        Assert.Equal(0, _session.Releases);
    }

    [Fact]
    public async Task LoadsDuringAReadShareIt()
    {
        _server.Windows = [FirstFields];
        var reading = new Gate();
        _server.Reading = reading;

        var first = _tab.LoadAsync();
        var second = _tab.LoadAsync();
        var more = _tab.LoadMoreAsync();
        await reading.Reached;
        reading.Open();
        await Task.WhenAll(first, second, more);

        Assert.Equal(1, Assert.Single(_server.Readers).Reads);
        Assert.Equal<string>(["reading", "rows", "window Hash 500 of 1200, 3780 s"], _view.Shown);
    }

    [Fact]
    public async Task ClosingDuringAReadStopsItShowsNothingAndLetsGoOnce()
    {
        _server.Windows = [FirstFields];
        var reading = new Gate();
        _server.Reading = reading;
        var loading = _tab.LoadAsync();
        await reading.Reached;

        await Task.WhenAll(_tab.CloseAsync(), _tab.CloseAsync());
        await loading;
        await _tab.LoadAsync();
        await _tab.LoadMoreAsync();

        Assert.Equal<string>(["reading"], _view.Shown);
        Assert.False(_tab.IsRunning);
        Assert.Null(_tab.Window);
        var reader = Assert.Single(_server.Readers);
        Assert.Equal((1, 0, 1), (reader.Reads, reader.RowsAsked, reader.Disposals));
        Assert.Equal(1, _session.Releases);
    }

    [Fact]
    public async Task ACloseWaitsForAReadThatDoesNotStopAndShowsNothingOfIt()
    {
        _server.Windows = [FirstFields];
        var reading = new Gate(honorsCancel: false);
        _server.Reading = reading;
        var loading = _tab.LoadAsync();
        await reading.Reached;

        var closing = _tab.CloseAsync();
        var reader = Assert.Single(_server.Readers);
        var waited = !closing.IsCompleted && _session.Releases == 0 && reader.Disposals == 0;
        reading.Open();
        await closing;
        await loading;

        Assert.True(waited);
        Assert.Equal<string>(["reading"], _view.Shown);
        Assert.Equal((0, 1), (reader.RowsAsked, reader.Disposals));
        Assert.Equal(1, _session.Releases);
    }

    [Fact]
    public async Task ACloseLetsTheGridGoOfItsRowsBeforeTheReaderAndTheSession()
    {
        _server.Windows = [FirstFields];
        await _tab.LoadAsync();

        await _tab.CloseAsync();

        Assert.Equal("released", _view.Shown[^1]);
        Assert.Equal(1, Assert.Single(_server.Readers).Disposals);
        Assert.Equal(1, _session.Releases);
        Assert.False(_tab.CanLoadMore);
    }

    [Fact]
    public async Task AKeyTabIsReadOnlyAndNamedForItsKey()
    {
        Assert.Equal("user:42", _tab.Title);
        Assert.Equal(TabKind.Key, _tab.Kind);
        Assert.Equal(TransactionState.Idle, _tab.Transaction);
        Assert.False(_tab.HasUnsavedChanges);
        Assert.True(await _tab.ConfirmCloseAsync(offerSave: true));
        Assert.Empty(_server.Readers);
    }

    [Fact]
    public void ASnapshotNamesTheKeyAndOpensItAgain()
    {
        var snapshot = _tab.Snapshot();

        Assert.Equal(new SessionTab { Kind = TabKind.Key, Title = "user:42", Table = "user:42" }, snapshot);
        Assert.Equal("user:42", KeyTab.KeyOf(snapshot));
        Assert.Null(KeyTab.KeyOf(snapshot with { Kind = TabKind.Table }));
        Assert.Null(KeyTab.KeyOf(snapshot with { Table = null }));
        Assert.Null(KeyTab.KeyOf(snapshot with { Table = string.Empty }));
    }
}

internal sealed class FakeKeyView : IKeyTabView
{
    public List<string> Shown { get; } = [];

    public void ShowReading() => Shown.Add("reading");

    public void ShowRows(ResultSet? rows) => Shown.Add("rows");

    public void ShowWindow(KeyWindow window) =>
        Shown.Add($"window {window.Kind} {window.Rows} of {window.Length}, {Expiry(window.Ttl)}");

    public void ReleaseRows() => Shown.Add("released");

    public void ShowMissing() => Shown.Add("missing");

    public void ShowFailure(CoreError failure) => Shown.Add("failed " + failure.Code);

    public void ShowStopped() => Shown.Add("stopped");

    private static string Expiry(KeyTtl ttl) => ttl switch
    {
        KeyTtl.ExpiresIn expires => $"{(long)expires.Left.TotalSeconds} s",
        KeyTtl.Persistent => "none",
        _ => "unknown",
    };
}

// The key as the server holds it; each reader opened reads it from its first window.
internal sealed class FakeKeyServer
{
    public List<KeyWindow?> Windows { get; set; } = [];

    public Gate? Reading { get; set; }

    public CoreError? Failure { get; set; }

    public List<FakeKeyRead> Readers { get; } = [];

    public IKeyRead Open()
    {
        var reader = new FakeKeyRead(this);
        Readers.Add(reader);
        return reader;
    }
}

internal sealed class FakeKeyRead(FakeKeyServer server) : IKeyRead
{
    private int _next;

    public int Reads { get; private set; }

    public int RowsAsked { get; private set; }

    public int Disposals { get; private set; }

    public async Task<KeyWindow?> ReadMoreAsync(CancellationToken cancellationToken)
    {
        ObjectDisposedException.ThrowIf(Disposals > 0, this);
        Reads++;
        if (server.Reading is { } reading)
        {
            await reading.PassAsync(cancellationToken);
        }

        if (server.Failure is { } failure)
        {
            throw new TableProException(failure);
        }

        if (server.Windows.Count == 0)
        {
            return null;
        }

        // Past the last window the reader reads nothing and gives the last one again.
        var window = server.Windows[Math.Min(_next, server.Windows.Count - 1)];
        _next++;
        return window;
    }

    public ResultSet? GetRows()
    {
        RowsAsked++;
        return null;
    }

    public void Dispose() => Disposals++;
}
