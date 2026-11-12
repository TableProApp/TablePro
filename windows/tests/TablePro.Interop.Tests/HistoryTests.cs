namespace TablePro.Interop.Tests;

public sealed class HistoryTests : IDisposable
{
    // Whole seconds, which is what the store keeps.
    private static readonly DateTimeOffset At = DateTimeOffset.FromUnixTimeSeconds(1_700_000_000);

    private readonly string _directory = Directory.CreateTempSubdirectory("tablepro-history-").FullName;
    private readonly TableProCore _core;

    public HistoryTests()
    {
        _core = TableProCore.Create(new HostConfiguration("test", _directory), new MemorySecretStore());
    }

    public void Dispose()
    {
        _core.Dispose();
        try
        {
            Directory.Delete(_directory, recursive: true);
        }
        catch (IOException)
        {
            // The history database closes on the core's own threads, which can still hold it here on Windows.
        }
    }

    [Fact]
    public async Task ARecordedRunIsFoundByItsWords()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        await using var session = await OpenAsync("app.sqlite", cancellationToken);
        using var history = await _core.OpenHistoryAsync(cancellationToken);

        var id = await history.RecordAsync(session, Ran("SELECT name FROM people", At), cancellationToken);
        var failed = Ran("SELECT nope FROM people", At.AddSeconds(1)) with
        {
            Outcome = new HistoryOutcome.Failed("no such column: nope"),
        };
        var refused = await history.RecordAsync(session, failed, cancellationToken);
        var named = await history.SearchAsync("name people", null, null, 50, cancellationToken);
        var both = await history.SearchAsync("PEOPLE", null, null, 50, cancellationToken);

        var entry = Assert.Single(named.Entries);
        Assert.Equal(id, entry.Id);
        Assert.Equal("SELECT name FROM people", entry.Sql);
        Assert.Equal(session.Id, entry.ConnectionId);
        Assert.Equal(session.Name, entry.ConnectionName);
        Assert.Equal("sqlite", entry.EngineId);
        Assert.Equal(At, entry.ExecutedAt);
        Assert.Equal(TimeSpan.FromMilliseconds(12), entry.Duration);
        Assert.Equal(3, entry.RowsAffected);
        Assert.Equal(HistoryOutcome.Succeeded.Instance, entry.Outcome);
        Assert.False(entry.Pinned);
        Assert.Null(named.Next);
        Assert.Equal([refused, id], both.Entries.Select(run => (long?)run.Id));
        Assert.Equal(new HistoryOutcome.Failed("no such column: nope"), both.Entries[0].Outcome);
    }

    [Fact]
    public async Task ASearchKeepsToTheConnectionItNames()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        await using var first = await OpenAsync("first.sqlite", cancellationToken);
        await using var second = await OpenAsync("second.sqlite", cancellationToken);
        using var history = await _core.OpenHistoryAsync(cancellationToken);

        var mine = await history.RecordAsync(first, Ran("SELECT 1", At), cancellationToken);
        await history.RecordAsync(second, Ran("SELECT 2", At.AddSeconds(1)), cancellationToken);
        var onlyFirst = await history.SearchAsync(string.Empty, first.Id, null, 50, cancellationToken);
        var every = await history.SearchAsync(string.Empty, null, null, 50, cancellationToken);

        Assert.Equal(mine, Assert.Single(onlyFirst.Entries).Id);
        Assert.Equal(2, every.Entries.Count);
    }

    [Fact]
    public async Task PagesFollowTheCursorAndShowNoRunTwice()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        await using var session = await OpenAsync("app.sqlite", cancellationToken);
        using var history = await _core.OpenHistoryAsync(cancellationToken);
        var ids = new List<long?>();
        for (var index = 0; index < 3; index++)
        {
            var run = Ran($"SELECT {index}", At.AddSeconds(index));
            ids.Add(await history.RecordAsync(session, run, cancellationToken));
        }

        var first = await history.SearchAsync(string.Empty, null, null, 2, cancellationToken);
        var second = await history.SearchAsync(string.Empty, null, first.Next, 2, cancellationToken);

        Assert.Equal([ids[2], ids[1]], first.Entries.Select(run => (long?)run.Id));
        Assert.NotNull(first.Next);
        Assert.Equal([ids[0]], second.Entries.Select(run => (long?)run.Id));
        Assert.Null(second.Next);
    }

    [Fact]
    public async Task ADeletedRunIsGoneAndClearRemovesTheRest()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        await using var session = await OpenAsync("app.sqlite", cancellationToken);
        using var history = await _core.OpenHistoryAsync(cancellationToken);
        var gone = await history.RecordAsync(session, Ran("SELECT 1", At), cancellationToken);
        var left = await history.RecordAsync(session, Ran("SELECT 2", At.AddSeconds(1)), cancellationToken);

        var id = gone ?? throw new InvalidOperationException("The run was not kept.");
        await history.DeleteAsync([id], cancellationToken);
        var afterDelete = await history.SearchAsync(string.Empty, null, null, 50, cancellationToken);
        await history.ClearAsync(cancellationToken);
        var afterClear = await history.SearchAsync(string.Empty, null, null, 50, cancellationToken);

        Assert.Equal(left, Assert.Single(afterDelete.Entries).Id);
        Assert.Empty(afterClear.Entries);
    }

    // SQLite withholds a statement that sets an encryption key, and text whose quote never closes.
    [Fact]
    public async Task AStatementTheEngineWithholdsIsNotKept()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        await using var session = await OpenAsync("app.sqlite", cancellationToken);
        using var history = await _core.OpenHistoryAsync(cancellationToken);

        var key = await history.RecordAsync(session, Ran("PRAGMA key = 'hunter2'", At), cancellationToken);
        var unclosed = await history.RecordAsync(session, Ran("SELECT 'hunter2", At), cancellationToken);
        var kept = await history.SearchAsync(string.Empty, null, null, 50, cancellationToken);

        Assert.Null(key);
        Assert.Null(unclosed);
        Assert.Empty(kept.Entries);
    }

    [Fact]
    public async Task ACoreWithoutStorageHasNoHistory()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        using var core = TableProCore.Create(new HostConfiguration("test"), new MemorySecretStore());

        var error = await Assert.ThrowsAsync<TableProException>(() => core.OpenHistoryAsync(cancellationToken));

        Assert.Equal("ffi.no_storage", error.Code);
    }

    private static HistoryRun Ran(string sql, DateTimeOffset at) =>
        new(sql, at, TimeSpan.FromMilliseconds(12), 3, HistoryOutcome.Succeeded.Instance);

    private Task<DatabaseSession> OpenAsync(string name, CancellationToken cancellationToken) =>
        _core.OpenFileAsync(new FileOpenOptions(Path.Combine(_directory, name), Create: true), cancellationToken);
}
