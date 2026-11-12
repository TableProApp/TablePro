using System.Diagnostics;

namespace TablePro.Interop.Tests;

public sealed class BrowseTests
{
    private static readonly TableName People = new(null, "people");

    [Fact]
    public async Task AFilteredPageReadsOnlyTheMatchingRowsAndCountsThem()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        await using var database = await SqliteDatabase.CreateAsync();
        var withNote = Rules(new FilterRule("note", FilterOperator.IsNotNull, null));

        var page = await database.Session.ReadTablePageAsync(People, null, withNote, 100, cancellationToken: cancellationToken);
        using var run = page.Run;
        var events = new List<QueryEvent>();
        await foreach (var queryEvent in run.ReadEventsAsync(cancellationToken))
        {
            events.Add(queryEvent);
        }

        using var set = run.GetResultSet(0);
        var count = await database.Session.CountRowsAsync(People, withNote, cancellationToken);
        var everyone = await database.Session.CountRowsAsync(People, cancellationToken: cancellationToken);

        Assert.Equal(3, page.VisibleColumns);
        Assert.True(page.CanSeek);
        Assert.IsType<QueryEvent.ResultSetStarted>(events[0]);
        Assert.Contains(new QueryEvent.RowsAppended(0, 2), events);
        var finished = Assert.IsType<QueryEvent.Finished>(events[^1]);
        Assert.IsType<QueryOutcome.Completed>(finished.Outcome);
        Assert.Equal(TransactionState.Idle, finished.Transaction);
        Assert.NotNull(set);
        Assert.Equal(["Grace", "Zoë 👋"], Texts(set, 1));
        Assert.Equal(2, count);
        Assert.Equal(SqliteDatabase.PeopleRows, everyone);
    }

    [Fact]
    public async Task ValuesBindAsTheColumnsTypeAndRawSqlJoinsTheRules()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        await using var database = await SqliteDatabase.CreateAsync();
        var idRange = Rules(new FilterRule("id", FilterOperator.Between, new FilterValue.Pair("2", "3")));
        var adaOrThird = new TableFilter(
            FilterCombinator.Or,
            [new FilterRule("name", FilterOperator.In, new FilterValue.List(["Ada"]))],
            "id = 3");

        var range = await database.Session.ReadTablePageAsync(
            People,
            new ColumnSort(0, Ascending: false),
            idRange,
            100,
            cancellationToken: cancellationToken);
        var either = await database.Session.ReadTablePageAsync(People, null, adaOrThird, 100, cancellationToken: cancellationToken);
        var count = await database.Session.CountRowsAsync(People, adaOrThird, cancellationToken);

        Assert.Equal(["Zoë 👋", "Grace"], await NamesAsync(range));
        Assert.Equal(["Ada", "Zoë 👋"], await NamesAsync(either));
        Assert.Equal(2, count);
    }

    [Fact]
    public async Task AFilterTheEngineCannotTakeThrowsBeforeAnyRead()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        await using var database = await SqliteDatabase.CreateAsync();
        var salary = Rules(new FilterRule("salary", FilterOperator.Greater, new FilterValue.One("1000")));
        var wordForNumber = Rules(new FilterRule("id", FilterOperator.Equal, new FilterValue.One("one")));
        var twoStatements = new TableFilter(FilterCombinator.And, [], "1=1; DROP TABLE people");

        var unknown = await Assert.ThrowsAsync<TableProException>(
            () => database.Session.ReadTablePageAsync(People, null, salary, 100, cancellationToken: cancellationToken));
        var uncounted = await Assert.ThrowsAsync<TableProException>(
            () => database.Session.CountRowsAsync(People, salary, cancellationToken));
        var typed = await Assert.ThrowsAsync<TableProException>(
            () => database.Session.ReadTablePageAsync(People, null, wordForNumber, 100, cancellationToken: cancellationToken));
        var injected = await Assert.ThrowsAsync<TableProException>(
            () => database.Session.ReadTablePageAsync(People, null, twoStatements, 100, cancellationToken: cancellationToken));
        var stillThere = await database.Session.CountRowsAsync(People, cancellationToken: cancellationToken);

        Assert.Equal("filter.unknown_column", unknown.Code);
        Assert.Equal("filter.unknown_column", uncounted.Code);
        Assert.Equal("edit.invalid_integer", typed.Code);
        Assert.Equal("filter.raw_predicate", injected.Code);
        Assert.Equal(SqliteDatabase.PeopleRows, stillThere);
    }

    [Fact]
    public async Task TheChoicesAreWhatTheEngineEvaluatesOnEachColumn()
    {
        await using var database = await SqliteDatabase.CreateAsync();

        var choices = await database.Session.GetFilterChoicesAsync(People, TestContext.Current.CancellationToken);

        Assert.Equal(["id", "name", "note"], choices.Columns.Select(column => column.Name));
        Assert.Contains(FilterOperator.Between, choices.Columns[0].Operators);
        Assert.DoesNotContain(FilterOperator.Contains, choices.Columns[0].Operators);
        Assert.Contains(FilterOperator.Contains, choices.Columns[1].Operators);
        Assert.Equal([FilterCombinator.And, FilterCombinator.Or], choices.Combinators);
        Assert.True(choices.AcceptsRawSql);
    }

    [Fact]
    public async Task TheTokenStopsAPageReadOnTheEngine()
    {
        await using var database = await SqliteDatabase.CreateAsync();
        await database.ExecuteAsync(
            "CREATE VIEW endless AS WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c) SELECT count(*) AS n FROM c");
        using var cancel = new CancellationTokenSource();

        var page = await database.Session.ReadTablePageAsync(
            new TableName(null, "endless"),
            null,
            null,
            100,
            cancellationToken: cancel.Token);
        using var run = page.Run;
        await Task.Delay(200, TestContext.Current.CancellationToken);
        var asked = Stopwatch.StartNew();
        await cancel.CancelAsync();
        var outcome = await run.Completion;
        var stopped = asked.Elapsed;
        var after = await database.Session.CountRowsAsync(People, cancellationToken: TestContext.Current.CancellationToken);

        Assert.IsType<QueryOutcome.Cancelled>(outcome);
        Assert.True(stopped < TimeSpan.FromSeconds(5), $"the read ended {stopped} after the cancel");
        Assert.Equal(SqliteDatabase.PeopleRows, after);
    }

    [Fact]
    public async Task ATablesStructureListsItsColumnsIndexForeignKeyAndCreateText()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        await using var database = await SqliteDatabase.CreateAsync();
        await database.ExecuteAsync("CREATE TABLE teams (id INTEGER PRIMARY KEY, name TEXT NOT NULL)");
        await database.ExecuteAsync(
            "CREATE TABLE players (id INTEGER PRIMARY KEY, team_id INTEGER REFERENCES teams (id) ON DELETE CASCADE, "
            + "name TEXT NOT NULL DEFAULT 'anon', score REAL)");
        await database.ExecuteAsync("CREATE INDEX players_by_score ON players (score DESC, name)");
        await database.ExecuteAsync("CREATE VIEW top_players AS SELECT name, score FROM players");

        var players = await database.Session.GetStructureAsync(new TableName(null, "players"), ObjectKind.Table, cancellationToken);
        var view = await database.Session.GetStructureAsync(new TableName(null, "top_players"), ObjectKind.View, cancellationToken);

        Assert.Equal(["id", "team_id", "name", "score"], players.Columns.Select(column => column.Name));
        Assert.True(players.Columns[0].PrimaryKey);
        Assert.False(players.Columns[2].Nullable);
        Assert.Equal("'anon'", players.Columns[2].DefaultValue);
        Assert.Null(players.Columns[3].DefaultValue);
        var index = Assert.Single(players.Indexes, entry => entry.Name == "players_by_score");
        Assert.Equal(["score DESC", "name"], index.Keys);
        Assert.False(index.Unique);
        var key = Assert.Single(players.ForeignKeys);
        Assert.Equal(["team_id"], key.Columns);
        Assert.Equal("teams", key.ReferencedTable);
        Assert.Equal(["id"], key.ReferencedColumns);
        Assert.Equal("CASCADE", key.OnDelete);
        Assert.NotNull(players.Ddl);
        Assert.Contains("CREATE TABLE", players.Ddl, StringComparison.Ordinal);
        Assert.Contains("players_by_score", players.Ddl, StringComparison.Ordinal);
        Assert.Equal(["name", "score"], view.Columns.Select(column => column.Name));
        Assert.Null(view.Ddl);
    }

    [Fact]
    public async Task ATriggersDefinitionReadsBackAndAFunctionIsUnsupportedOnSqlite()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        await using var database = await SqliteDatabase.CreateAsync();
        await database.ExecuteAsync(
            "CREATE TRIGGER people_noted AFTER INSERT ON people BEGIN UPDATE people SET note = 'new' WHERE id = new.id; END");

        var objects = await database.Session.RefreshObjectsAsync(ObjectScope.DefaultSchema, cancellationToken);
        var trigger = Assert.Single(objects, entry => entry.Kind == ObjectKind.Trigger);
        var source = await database.Session.GetObjectDefinitionAsync(trigger, cancellationToken);
        var function = await Assert.ThrowsAsync<TableProException>(() => database.Session.GetObjectDefinitionAsync(
            new ObjectEntry(null, "total", ObjectKind.Function, null),
            cancellationToken));

        Assert.Equal("people_noted", trigger.Name);
        Assert.Equal("people", trigger.ParentTable);
        Assert.NotNull(source);
        Assert.Contains("CREATE TRIGGER", source.Sql, StringComparison.Ordinal);
        Assert.Contains("people_noted", source.Sql, StringComparison.Ordinal);
        Assert.True(source.OpensInEditor);
        Assert.Null(source.Database);
        Assert.Equal("driver.unsupported", function.Code);
    }

    private static TableFilter Rules(params FilterRule[] rules) => new(FilterCombinator.And, rules, null);

    private static List<string?> Texts(ResultSet set, int column) =>
        [.. Enumerable.Range(0, (int)set.RowCount).Select(row => set.GetCellText(row, column))];

    private static async Task<List<string?>> NamesAsync(TablePageRun page)
    {
        using var run = page.Run;
        Assert.IsType<QueryOutcome.Completed>(await run.Completion);
        using var set = run.GetResultSet(0);
        Assert.NotNull(set);
        return Texts(set, 1);
    }
}
