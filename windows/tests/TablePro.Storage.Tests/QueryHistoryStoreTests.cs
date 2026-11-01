using TablePro.Core.Connections;
using TablePro.Core.Sql;
using TablePro.Storage.History;

namespace TablePro.Storage.Tests;

public sealed class QueryHistoryStoreTests : IDisposable
{
    private static readonly DateTimeOffset Start = new(2026, 10, 1, 9, 0, 0, TimeSpan.Zero);
    private readonly TempDirectory _temp = new();
    private readonly QueryHistoryStore _store;
    private readonly Guid _connection = Guid.NewGuid();
    private readonly Guid _other = Guid.NewGuid();

    public QueryHistoryStoreTests()
    {
        _store = new QueryHistoryStore(_temp.Paths);
    }

    private static CancellationToken Token => TestContext.Current.CancellationToken;

    public void Dispose()
    {
        _store.Dispose();
        _temp.Dispose();
    }

    [Fact]
    public async Task RecordedEntriesReadBackNewestFirstWithEveryField()
    {
        var entry = QueryHistoryEntry.Create(
            "UPDATE accounts SET active = false WHERE id = 7",
            _connection,
            DatabaseEngine.PostgreSql,
            TimeSpan.FromMilliseconds(12.5),
            rowCount: 1,
            databaseName: "app",
            schemaName: "public",
            source: QueryHistorySource.Editor,
            executedAt: Start);
        await _store.RecordAsync(entry, Token);
        await _store.RecordAsync(Entry("SELECT 1", Start.AddMinutes(1)), Token);

        var page = await _store.SearchAsync(new QueryHistoryFilter(), cancellationToken: Token);

        Assert.Equal(2, page.Entries.Count);
        Assert.Null(page.NextCursor);
        Assert.Equal("SELECT 1", page.Entries[0].Query);
        var loaded = page.Entries[1];
        Assert.Equal(entry, loaded);
        Assert.Equal(StatementKind.Write, loaded.StatementKind);
        Assert.Equal(StatementKind.Read, page.Entries[0].StatementKind);
    }

    [Fact]
    public async Task FullTextSearchMatchesWordPrefixesInAnyOrder()
    {
        await _store.RecordAsync(Entry("SELECT * FROM customers WHERE region = 'EU'", Start), Token);
        await _store.RecordAsync(Entry("SELECT * FROM orders", Start.AddSeconds(1)), Token);
        await _store.RecordAsync(Entry("DELETE FROM customer_notes", Start.AddSeconds(2)), Token);

        Assert.Equal(2, (await Search("cust")).Count);
        Assert.Single(await Search("custom regi"));
        Assert.Single(await Search("region sel"));
        Assert.Empty(await Search("invoices"));

        // FTS5 operators and quotes in the search text are searched as text, not parsed.
        Assert.Empty(await Search("NOT \"orders"));
        Assert.Single(await Search("\"orders\""));
    }

    [Fact]
    public async Task FiltersByConnectionOutcomeDateAndSource()
    {
        await _store.RecordAsync(Entry("SELECT 1", Start), Token);
        await _store.RecordAsync(Entry("SELECT 2", Start.AddHours(1)) with { Success = false, ErrorMessage = "boom" }, Token);
        await _store.RecordAsync(Entry("SELECT 3", Start.AddHours(2)) with { ConnectionId = _other }, Token);
        await _store.RecordAsync(Entry("SELECT 4", Start.AddHours(3)) with { Source = QueryHistorySource.TableBrowse }, Token);

        Assert.Equal(3, (await Filter(new() { ConnectionId = _connection })).Count);
        Assert.Equal(["SELECT 2"], (await Filter(new() { Outcome = QueryHistoryOutcome.Failed })).Select(e => e.Query));
        Assert.Equal(3, (await Filter(new() { Outcome = QueryHistoryOutcome.Succeeded })).Count);
        Assert.Equal(
            ["SELECT 3", "SELECT 2"],
            (await Filter(new() { Since = Start.AddMinutes(30), Until = Start.AddHours(2) })).Select(e => e.Query));
        Assert.Equal(
            ["SELECT 4"],
            (await Filter(new() { Sources = new HashSet<QueryHistorySource> { QueryHistorySource.TableBrowse } })).Select(e => e.Query));
        Assert.Empty(await Filter(new() { Since = Start.AddDays(1), Until = Start }));
        Assert.Equal(3, await _store.CountAsync(new QueryHistoryFilter { ConnectionId = _connection }, Token));
    }

    [Fact]
    public async Task PagingWalksEveryEntryOnceEvenWithIdenticalTimestamps()
    {
        for (var i = 0; i < 25; i++)
        {
            await _store.RecordAsync(Entry($"SELECT {i}", Start.AddSeconds(i / 5)), Token);
        }

        var seen = new List<Guid>();
        QueryHistoryCursor? cursor = null;
        var pages = 0;
        do
        {
            var page = await _store.SearchAsync(new QueryHistoryFilter(), pageSize: 7, after: cursor, cancellationToken: Token);
            seen.AddRange(page.Entries.Select(e => e.Id));
            cursor = page.NextCursor;
            pages++;
        }
        while (cursor is not null);

        Assert.Equal(4, pages);
        Assert.Equal(25, seen.Count);
        Assert.Equal(25, seen.Distinct().Count());
    }

    [Fact]
    public async Task DeleteAndClearRemoveEntriesAndTheirSearchIndex()
    {
        var keep = Entry("SELECT keepme", Start);
        var drop = Entry("SELECT dropme", Start.AddSeconds(1));
        await _store.RecordAsync(keep, Token);
        await _store.RecordAsync(drop, Token);
        await _store.RecordAsync(Entry("SELECT elsewhere", Start) with { ConnectionId = _other }, Token);

        Assert.True(await _store.DeleteAsync(drop.Id, Token));
        Assert.False(await _store.DeleteAsync(drop.Id, Token));
        Assert.Empty(await Search("dropme"));

        Assert.Equal(1, await _store.ClearAsync(_connection, Token));
        Assert.Empty(await Search("keepme"));
        Assert.Single(await Search("elsewhere"));

        Assert.Equal(1, await _store.ClearAsync(null, Token));
        Assert.Equal(0, await _store.CountAsync(cancellationToken: Token));
    }

    [Fact]
    public async Task PruneKeepsTheNewestWithinCountAndAge()
    {
        var now = DateTimeOffset.UtcNow;
        for (var i = 0; i < 10; i++)
        {
            await _store.RecordAsync(Entry($"SELECT {i}", now.AddMinutes(-i)), Token);
        }

        await _store.RecordAsync(Entry("SELECT ancient", now.AddDays(-400)), Token);

        Assert.Equal(1, await _store.PruneAsync(new QueryHistoryRetention(MaxEntries: null, MaxAge: TimeSpan.FromDays(365)), Token));
        Assert.Equal(4, await _store.PruneAsync(new QueryHistoryRetention(MaxEntries: 6), Token));

        var remaining = (await _store.SearchAsync(new QueryHistoryFilter(), cancellationToken: Token)).Entries;
        Assert.Equal(["SELECT 0", "SELECT 1", "SELECT 2", "SELECT 3", "SELECT 4", "SELECT 5"], remaining.Select(e => e.Query));
        Assert.Empty(await Search("ancient"));
    }

    [Fact]
    public async Task ChangedFiresWhenEntriesAreAddedOrRemoved()
    {
        var count = 0;
        _store.Changed += (_, _) => Interlocked.Increment(ref count);
        var entry = Entry("SELECT 1", Start);

        await _store.RecordAsync(entry, Token);
        await _store.DeleteAsync(entry.Id, Token);
        await _store.DeleteAsync(entry.Id, Token);

        Assert.Equal(2, count);
    }

    [Theory]
    [InlineData("sel cust", "\"sel\"* AND \"cust\"*")]
    [InlineData("say \"hi\"", "\"say\"* AND \"\"\"hi\"\"\"*")]
    [InlineData("OR", "\"OR\"*")]
    public void FtsQueryQuotesEveryTerm(string text, string expected) =>
        Assert.Equal(expected, QueryHistoryStore.FtsQuery(text));

    private QueryHistoryEntry Entry(string query, DateTimeOffset at) =>
        QueryHistoryEntry.Create(query, _connection, DatabaseEngine.PostgreSql, TimeSpan.FromMilliseconds(3), 1, executedAt: at);

    private async Task<IReadOnlyList<QueryHistoryEntry>> Search(string text) =>
        (await _store.SearchAsync(new QueryHistoryFilter { SearchText = text }, cancellationToken: Token)).Entries;

    private async Task<IReadOnlyList<QueryHistoryEntry>> Filter(QueryHistoryFilter filter) =>
        (await _store.SearchAsync(filter, cancellationToken: Token)).Entries;
}
