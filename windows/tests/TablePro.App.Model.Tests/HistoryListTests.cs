using System.Runtime.CompilerServices;
using TablePro.Interop;

namespace TablePro.App.Model.Tests;

public sealed class HistoryListTests
{
    private static readonly Guid Chinook = Guid.Parse("8f14e45f-ceea-467f-a8f5-7b1c3f0a5d21");

    private readonly FakeHistoryStore _store = new();

    public HistoryListTests()
    {
        for (var id = 1; id <= 5; id++)
        {
            _store.Entries.Insert(0, FakeHistoryStore.Entry(id, $"select {id} from Artist", Chinook));
        }
    }

    [Fact]
    public async Task ASearchListsTheConnectionsRunsAPageAtATime()
    {
        var list = new HistoryList(_store, Chinook, pageSize: 2);

        await list.SearchAsync("artist");

        Assert.Equal<long>([5, 4], Ids(list));
        Assert.True(list.HasMore);

        await list.LoadMoreAsync();
        await list.LoadMoreAsync();

        Assert.Equal<long>([5, 4, 3, 2, 1], Ids(list));
        Assert.False(list.HasMore);

        await list.LoadMoreAsync();

        Assert.Equal<int>([0, 2, 4], _store.Searches.Select(search => search.Offset));
        Assert.All(_store.Searches, search => Assert.Equal(("artist", 2), (search.Text, search.Limit)));
        Assert.All(_store.Searches, search => Assert.Equal(Chinook, search.ConnectionId));
        Assert.Equal("artist", list.Text);
        Assert.Null(list.Failure);
    }

    [Fact]
    public async Task ASearchIsLoadingFromItsStartToItsAnswer()
    {
        var list = new HistoryList(_store, Chinook);
        List<bool> loading = [];
        list.Changed += (_, _) => loading.Add(list.IsLoading);

        await list.SearchAsync(string.Empty);

        Assert.Equal<bool>([true, false], loading);
        Assert.Equal(5, list.Entries.Count);
    }

    [Fact]
    public async Task TheNewestSearchWinsAndAnOlderAnswerIsDropped()
    {
        var older = new Gate();
        var newer = new Gate();
        _store.Searching["select"] = older;
        _store.Searching["select 3"] = newer;
        var list = new HistoryList(_store, Chinook);

        var first = list.SearchAsync("select");
        await older.Reached;
        var second = list.SearchAsync("select 3");
        await newer.Reached;
        older.Open();
        await first;

        Assert.True(list.IsLoading);
        Assert.Empty(list.Entries);

        newer.Open();
        await second;

        Assert.False(list.IsLoading);
        Assert.Equal<long>([3], Ids(list));
        Assert.Equal("select 3", list.Text);
    }

    [Fact]
    public async Task MoreIsNotReadWhileLoadingAndANewSearchDropsAPageInFlight()
    {
        var list = new HistoryList(_store, Chinook, pageSize: 2);
        await list.SearchAsync(string.Empty);
        var paging = new Gate();
        _store.Paging = paging;

        var more = list.LoadMoreAsync();
        await paging.Reached;
        await list.LoadMoreAsync();

        Assert.Equal(2, _store.Searches.Count);

        _store.Paging = null;
        await list.SearchAsync("select 1");
        paging.Open();
        await more;

        Assert.Equal<long>([1], Ids(list));
        Assert.False(list.HasMore);
        Assert.False(list.IsLoading);
    }

    [Fact]
    public async Task ARefreshSearchesTheSameTextAgain()
    {
        var list = new HistoryList(_store, Chinook);
        await list.SearchAsync("artist");
        _store.Entries.Insert(0, FakeHistoryStore.Entry(6, "select 6 from Artist", Chinook));

        await list.RefreshAsync();

        Assert.Equal<long>([6, 5, 4, 3, 2, 1], Ids(list));
        Assert.Equal("artist", _store.Searches[^1].Text);
    }

    [Fact]
    public async Task ADeletedRunLeavesTheListAndTheStore()
    {
        var list = new HistoryList(_store, Chinook);
        await list.SearchAsync(string.Empty);

        await list.DeleteAsync(list.Entries[1]);

        Assert.Equal<long>([5, 3, 2, 1], Ids(list));
        Assert.Equal<long>([4], Assert.Single(_store.Deleted));
        Assert.DoesNotContain(_store.Entries, entry => entry.Id == 4);
    }

    [Fact]
    public async Task ARunDeletedWhileASearchWasReadStaysOut()
    {
        var list = new HistoryList(_store, Chinook);
        await list.SearchAsync(string.Empty);
        var reading = new Gate();
        _store.Searching[string.Empty] = reading;

        var refreshing = list.RefreshAsync();
        await reading.Reached;
        await list.DeleteAsync(list.Entries[0]);
        reading.Open();
        await refreshing;

        Assert.Equal<long>([4, 3, 2, 1], Ids(list));
    }

    [Fact]
    public async Task ClearEmptiesTheListAndDropsASearchInFlight()
    {
        var list = new HistoryList(_store, Chinook, pageSize: 2);
        await list.SearchAsync(string.Empty);
        var reading = new Gate();
        _store.Searching["select"] = reading;
        var searching = list.SearchAsync("select");
        await reading.Reached;

        await list.ClearAsync();

        Assert.Empty(list.Entries);
        Assert.False(list.HasMore);
        Assert.False(list.IsLoading);
        Assert.Equal(1, _store.Clears);

        reading.Open();
        await searching;

        Assert.Empty(list.Entries);
        Assert.False(list.IsLoading);
    }

    [Fact]
    public async Task AFailureIsKeptForTheViewAndNeverThrown()
    {
        var list = new HistoryList(_store, Chinook);
        await list.SearchAsync(string.Empty);
        _store.Failure = Errors.Of("history.unavailable");

        await list.DeleteAsync(list.Entries[0]);
        await list.ClearAsync();

        Assert.Equal("history.unavailable", list.Failure?.Code);
        Assert.Equal(5, list.Entries.Count);

        await list.SearchAsync("select 2");

        Assert.Equal("history.unavailable", list.Failure?.Code);
        Assert.Empty(list.Entries);
        Assert.False(list.IsLoading);

        _store.Failure = null;
        await list.RefreshAsync();

        Assert.Null(list.Failure);
        Assert.Equal<long>([2], Ids(list));
    }

    [Fact]
    public async Task APageThatFailsKeepsTheRunsShownAndCanBeAskedForAgain()
    {
        var list = new HistoryList(_store, Chinook, pageSize: 2);
        await list.SearchAsync(string.Empty);
        _store.Failure = Errors.Of("history.unavailable");

        await list.LoadMoreAsync();

        Assert.Equal<long>([5, 4], Ids(list));
        Assert.True(list.HasMore);
        Assert.NotNull(list.Failure);

        _store.Failure = null;
        await list.LoadMoreAsync();

        Assert.Equal<long>([5, 4, 3, 2], Ids(list));
        Assert.Null(list.Failure);
    }

    private static IEnumerable<long> Ids(HistoryList list) => list.Entries.Select(entry => entry.Id);
}

// Newest first, paged by offset behind a cursor only it reads back, as the core's store pages.
internal sealed class FakeHistoryStore : IHistoryStore
{
    private readonly Dictionary<HistoryCursor, int> _cursors = new(ReferenceEqualityComparer.Instance);

    public List<HistoryEntry> Entries { get; } = [];

    public List<(string Text, Guid? ConnectionId, int Offset, int Limit)> Searches { get; } = [];

    // Waited at by a first page searched for that text, once its runs are read, so a later delete misses them.
    public Dictionary<string, Gate> Searching { get; } = [];

    // Waited at by each later page, once its runs are read.
    public Gate? Paging { get; set; }

    public CoreError? Failure { get; set; }

    public List<IReadOnlyList<long>> Deleted { get; } = [];

    public int Clears { get; private set; }

    public static HistoryEntry Entry(long id, string sql, Guid? connectionId) => new(
        id,
        sql,
        connectionId,
        "Chinook",
        "sqlite",
        DateTimeOffset.FromUnixTimeSeconds(1_700_000_000 + id),
        TimeSpan.FromMilliseconds(4),
        null,
        HistoryOutcome.Succeeded.Instance,
        Pinned: false);

    public async Task<HistoryPage> SearchAsync(
        string text,
        Guid? connectionId,
        HistoryCursor? after,
        int limit,
        CancellationToken cancellationToken)
    {
        var offset = after is null ? 0 : _cursors[after];
        Searches.Add((text, connectionId, offset, limit));
        if (Failure is { } failure)
        {
            throw new TableProException(failure);
        }

        var found = Entries
            .Where(entry => connectionId is null || entry.ConnectionId == connectionId)
            .Where(entry => entry.Sql.Contains(text, StringComparison.OrdinalIgnoreCase))
            .ToList();
        var page = found.Skip(offset).Take(limit).ToList();
        HistoryCursor? next = null;
        if (offset + page.Count < found.Count)
        {
            next = Cursor();
            _cursors.Add(next, offset + page.Count);
        }

        if ((after is null ? Searching.GetValueOrDefault(text) : Paging) is { } wait)
        {
            await wait.PassAsync(cancellationToken);
        }

        return new HistoryPage(page, next);
    }

    public Task DeleteAsync(IReadOnlyList<long> ids, CancellationToken cancellationToken)
    {
        if (Failure is { } failure)
        {
            return Task.FromException(new TableProException(failure));
        }

        Deleted.Add(ids);
        Entries.RemoveAll(entry => ids.Contains(entry.Id));
        return Task.CompletedTask;
    }

    public Task ClearAsync(CancellationToken cancellationToken)
    {
        if (Failure is { } failure)
        {
            return Task.FromException(new TableProException(failure));
        }

        Clears++;
        Entries.Clear();
        return Task.CompletedTask;
    }

    // Only the core makes a cursor; a test needs one it can tell apart from the others.
    private static HistoryCursor Cursor() =>
        (HistoryCursor)RuntimeHelpers.GetUninitializedObject(typeof(HistoryCursor));
}
