using System.Text;

namespace TablePro.Interop.Tests;

public sealed class VerticalPathTests
{
    [Fact]
    public void EveryEngineOfTheFirstReleaseIsLinkedIn()
    {
        using var core = TableProCore.Create(new HostConfiguration("test"), new MemorySecretStore());

        var ids = core.Engines.Select(engine => engine.Id).Order().ToList();
        var sqlite = core.Engines.Single(engine => engine.Id == "sqlite");

        Assert.Equal(
            ["cassandra", "clickhouse", "duckdb", "mongodb", "mssql", "mysql", "postgres", "redis", "sqlite"],
            ids);
        Assert.Contains("sqlite3", sqlite.FileSuffixes);
        Assert.Null(sqlite.DefaultPort);
        Assert.Equal(5432, core.Engines.Single(engine => engine.Id == "postgres").DefaultPort);
    }

    [Fact]
    public async Task TheCatalogListsEachLevelWhenAskedFor()
    {
        await using var database = await SqliteDatabase.CreateAsync();
        var session = database.Session;

        var cancellationToken = TestContext.Current.CancellationToken;

        var schemas = await session.GetSchemasAsync(cancellationToken);
        var objects = await session.RefreshObjectsAsync(ObjectScope.DefaultSchema, cancellationToken);
        var cached = await session.GetObjectsAsync(ObjectScope.DefaultSchema, cancellationToken);
        var columns = await session.GetColumnsAsync(new TableName(null, "people"), cancellationToken);

        Assert.Contains(schemas, schema => schema.IsDefault);
        var people = Assert.Single(objects, entry => entry.Name == "people");
        Assert.Equal(ObjectKind.Table, people.Kind);
        Assert.Equal(objects, cached);
        Assert.Equal(["id", "name", "note"], columns.Select(column => column.Name));
        Assert.Equal(ValueKind.Integer, columns[0].ValueKind);
        Assert.True(columns[0].IsPrimaryKey);
        Assert.Equal(ValueKind.Text, columns[1].ValueKind);
        Assert.False(columns[1].IsNullable);
        Assert.Equal("app.sqlite", session.Name);
        Assert.Equal("sqlite", session.EngineId);
    }

    [Fact]
    public async Task ATableAndAQueryResultSortOnTheServer()
    {
        await using var database = await SqliteDatabase.CreateAsync();
        var cancellationToken = TestContext.Current.CancellationToken;

        var table = await database.Session.GetTableQueryAsync(
            new TableName(null, "people"),
            new ColumnSort(1, Ascending: false),
            100,
            cancellationToken: cancellationToken);
        var query = database.Session.SortedQuery("SELECT name FROM people LIMIT 2", ["name"], 0, ascending: true);
        var joined = database.Session.SortedQuery(
            "SELECT a.id, b.id FROM people a JOIN people b ON b.id = 4 - a.id",
            ["id", "id"],
            1,
            ascending: true);
        var write = database.Session.SortedQuery("UPDATE people SET note = NULL", ["name"], 0, ascending: true);

        Assert.Equal(["Zoë 👋", "Grace", "Ada"], await Column(database, table.Sql, 1));
        Assert.NotNull(query);
        Assert.Equal(["Ada", "Grace"], await Column(database, query, 0));
        Assert.NotNull(joined);
        Assert.EndsWith("ORDER BY 2 ASC", joined, StringComparison.Ordinal);
        Assert.Equal(["3", "2", "1"], await Column(database, joined, 0));
        Assert.Null(write);
    }

    [Fact]
    public async Task ATablePagesPastItsFirstRowsAndCountsThemAll()
    {
        await using var database = await SqliteDatabase.CreateAsync();
        var cancellationToken = TestContext.Current.CancellationToken;
        var people = new TableName(null, "people");

        var second = await database.Session.GetTableQueryAsync(people, null, 2, 2, cancellationToken);
        var count = await database.Session.CountRowsAsync(people, cancellationToken);

        Assert.True(second.CanSeek);
        Assert.Equal(["3"], await Column(database, second.Sql, 0));
        Assert.Equal(SqliteDatabase.PeopleRows, count);
    }

    [Fact]
    public async Task ARunSaysWhichTransactionItLeavesOpen()
    {
        await using var database = await SqliteDatabase.CreateAsync();

        var began = await Finished(database, "BEGIN");
        var lost = database.Editor.IsLost;
        var rolledBack = await Finished(database, "ROLLBACK");

        Assert.Equal(TransactionState.InTransaction, began.Transaction);
        Assert.Equal(TransactionState.Idle, rolledBack.Transaction);
        Assert.False(lost);
    }

    [Fact]
    public async Task AnOpenFileIsOnlineUntilTheWaitIsCancelled()
    {
        await using var database = await SqliteDatabase.CreateAsync();
        using var cancel = new CancellationTokenSource();

        var health = database.Session.Health;
        var wait = database.Session.WaitForHealthChangeAsync(health, cancel.Token);
        await cancel.CancelAsync();

        Assert.IsType<SessionHealth.Online>(health);
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => wait);
    }

    private static async Task<QueryEvent.Finished> Finished(SqliteDatabase database, string sql)
    {
        using var run = database.Editor.Run(sql, cancellationToken: TestContext.Current.CancellationToken);
        QueryEvent? last = null;
        await foreach (var queryEvent in run.ReadEventsAsync(TestContext.Current.CancellationToken))
        {
            last = queryEvent;
        }

        return Assert.IsType<QueryEvent.Finished>(last);
    }

    [Fact]
    public async Task AResultThatCannotRunAgainSortsTheRowsItHolds()
    {
        await using var database = await SqliteDatabase.CreateAsync();
        using var run = database.Editor.Run(
            "SELECT name, note FROM people",
            cancellationToken: TestContext.Current.CancellationToken);
        Assert.IsType<QueryOutcome.Completed>(await run.Completion);
        using var set = run.GetResultSet(0);
        Assert.NotNull(set);

        using var descending = await set.SortedAsync(0, ascending: false);
        using var byNote = await set.SortedAsync(1, ascending: true);
        using var cursor = descending.OpenCursor();
        var window = cursor.Fetch(0, 10, 0, 1, 64);

        Assert.Equal(set.RowCount, descending.RowCount);
        string?[] names = [window.GetText(0, 0), window.GetText(1, 0), window.GetText(2, 0)];
        Assert.Equal(["Zoë 👋", "Grace", "Ada"], names);
        Assert.Null(byNote.GetCellText(0, 1));
        Assert.Equal("Ada", byNote.GetCellText(0, 0));
        Assert.Equal("Ada", set.GetCellText(0, 0));
        await Assert.ThrowsAsync<TableProException>(() => set.SortedAsync(5, ascending: true));
    }

    private static async Task<List<string?>> Column(SqliteDatabase database, string sql, int column)
    {
        using var run = database.Editor.Run(sql, cancellationToken: TestContext.Current.CancellationToken);
        Assert.IsType<QueryOutcome.Completed>(await run.Completion);
        using var set = run.GetResultSet(0);
        Assert.NotNull(set);
        return [.. Enumerable.Range(0, (int)set.RowCount).Select(row => set.GetCellText(row, column))];
    }

    [Fact]
    public async Task AQueryStreamsIntoAResultSetThatAWindowReads()
    {
        await using var database = await SqliteDatabase.CreateAsync();

        using var run = database.Editor.Run(
            "SELECT id, name, note FROM people ORDER BY id",
            cancellationToken: TestContext.Current.CancellationToken);
        var events = new List<QueryEvent>();
        await foreach (var queryEvent in run.ReadEventsAsync(TestContext.Current.CancellationToken))
        {
            events.Add(queryEvent);
        }

        var outcome = await run.Completion;
        Assert.IsType<QueryOutcome.Completed>(outcome);
        var started = Assert.IsType<QueryEvent.ResultSetStarted>(events[0]);
        Assert.Equal(["id", "name", "note"], started.Columns.Select(column => column.Name));
        Assert.Contains(new QueryEvent.RowsAppended(0, SqliteDatabase.PeopleRows), events);
        Assert.IsType<QueryEvent.Finished>(events[^1]);

        using var set = run.GetResultSet(0);
        Assert.NotNull(set);
        Assert.Equal(SqliteDatabase.PeopleRows, set.RowCount);
        Assert.True(set.IsFinished);
        Assert.Equal("line one\nline two", set.GetCellText(1, 2));
        Assert.Null(set.GetCellText(0, 2));

        using var cursor = set.OpenCursor();
        var window = cursor.Fetch(0, 50, 0, 3, 6);
        Assert.Equal(3, window.RowCount);
        Assert.Equal(3, window.ColumnCount);
        Assert.Equal(SqliteDatabase.PeopleRows, window.TotalRows);
        Assert.True(window.IsFinished);
        Assert.Equal("1", window.GetText(0, 0));
        Assert.Equal(3, window.GetRaw(2, 0));
        Assert.Equal(ValueKind.Integer, window.GetKind(0, 0));
        Assert.Equal("Zoë 👋", window.GetText(2, 1));
        Assert.Equal(ValueKind.Text, window.GetKind(2, 1));
        Assert.Equal(Encoding.UTF8.GetByteCount("Zoë 👋"), window.GetRaw(2, 1));
        Assert.True(window.IsNull(0, 2));
        Assert.Null(window.GetText(0, 2));
        Assert.Equal("line o", window.GetText(1, 2));
        Assert.True(window.IsTruncated(1, 2));
        Assert.Equal("中文", window.GetText(2, 2));
        Assert.False(window.IsTruncated(2, 2));
    }

    [Fact]
    public async Task AWindowOutlivedByALaterFetchRefusesToBeRead()
    {
        await using var database = await SqliteDatabase.CreateAsync();
        using var run = database.Editor.Run(
            "SELECT id FROM people",
            cancellationToken: TestContext.Current.CancellationToken);
        await run.Completion;
        using var set = run.GetResultSet(0)!;
        using var cursor = set.OpenCursor();

        var first = cursor.Fetch(0, 1, 0, 1, 10).RowCount;
        cursor.Fetch(1, 1, 0, 1, 10);

        Assert.Equal(1, first);
        Assert.Throws<InvalidOperationException>(() => ReadStale(cursor));
    }

    private static string? ReadStale(ResultCursor cursor)
    {
        var stale = cursor.Fetch(0, 1, 0, 1, 10);
        cursor.Fetch(2, 1, 0, 1, 10);
        return stale.GetText(0, 0);
    }
}
