using System.Diagnostics;

namespace TablePro.Interop.Tests;

public sealed class ExportTests
{
    private static readonly TableName People = new(null, "people");

    [Fact]
    public async Task CsvOfAResultHoldsExactlyItsRows()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        await using var database = await SqliteDatabase.CreateAsync();
        var path = Beside(database, "people.csv");
        await File.WriteAllTextAsync(path, "an older export", cancellationToken);
        using var run = database.Editor.Run(
            "SELECT id, name, note FROM people ORDER BY id", cancellationToken: cancellationToken);
        Assert.IsType<QueryOutcome.Completed>(await run.Completion);
        using var set = run.GetResultSet(0) ?? throw new InvalidOperationException("The read held no set.");

        var rows = await database.Session.ExportRowsAsync(
            set, 3, ExportFormat.Csv, null, path, cancellationToken: cancellationToken);

        Assert.Equal(3, rows);
        Assert.Equal(
            "id,name,note\n1,Ada,\n2,Grace,\"line one\nline two\"\n3,Zoë 👋,中文\n",
            await File.ReadAllTextAsync(path, cancellationToken));
    }

    [Fact]
    public async Task APageExportsOnlyItsVisibleColumns()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        await using var database = await SqliteDatabase.CreateAsync();
        await database.ExecuteAsync("CREATE TABLE notes (body TEXT)");
        await database.ExecuteAsync("INSERT INTO notes VALUES ('first'), ('second')");
        var notes = new TableName(null, "notes");
        var path = Beside(database, "notes.csv");
        var page = await database.Session.ReadTablePageAsync(
            notes, null, null, 100, cancellationToken: cancellationToken);
        using var run = page.Run;
        Assert.IsType<QueryOutcome.Completed>(await run.Completion);
        using var set = run.GetResultSet(0) ?? throw new InvalidOperationException("The page read no set.");
        Assert.True(set.GetColumns().Count > page.VisibleColumns, "A table with no key pages by its row address.");

        var rows = await database.Session.ExportRowsAsync(
            set, page.VisibleColumns, ExportFormat.Csv, notes, path, cancellationToken: cancellationToken);

        Assert.Equal(2, rows);
        Assert.Equal("body\nfirst\nsecond\n", await File.ReadAllTextAsync(path, cancellationToken));
    }

    [Fact]
    public async Task SqlInsertOfAResultWritesIntoTheTableItsColumnsCameFrom()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        await using var database = await SqliteDatabase.CreateAsync();
        var path = Beside(database, "people.sql");
        using var run = database.Editor.Run("SELECT id, name FROM people ORDER BY id", cancellationToken: cancellationToken);
        Assert.IsType<QueryOutcome.Completed>(await run.Completion);
        using var set = run.GetResultSet(0) ?? throw new InvalidOperationException("The read held no set.");

        var rows = await database.Session.ExportRowsAsync(
            set, 2, ExportFormat.SqlInsert, null, path, cancellationToken: cancellationToken);

        Assert.Equal(3, rows);
        var first = (await File.ReadAllLinesAsync(path, cancellationToken))[0];
        Assert.Equal("INSERT INTO \"people\" (\"id\", \"name\") VALUES (1, 'Ada');", first);
    }

    [Fact]
    public async Task SqlInsertOfAComputedResultWritesIntoQueryResults()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        await using var database = await SqliteDatabase.CreateAsync();
        var path = Beside(database, "loud.sql");
        using var run = database.Editor.Run(
            "SELECT id, upper(name) AS loud FROM people ORDER BY id", cancellationToken: cancellationToken);
        Assert.IsType<QueryOutcome.Completed>(await run.Completion);
        using var set = run.GetResultSet(0) ?? throw new InvalidOperationException("The read held no set.");

        await database.Session.ExportRowsAsync(
            set, 2, ExportFormat.SqlInsert, null, path, cancellationToken: cancellationToken);

        var first = (await File.ReadAllLinesAsync(path, cancellationToken))[0];
        Assert.Equal("INSERT INTO \"query_results\" (\"id\", \"loud\") VALUES (1, 'ADA');", first);
    }

    [Fact]
    public async Task AnExportReportsTheRowsWrittenWhileItRuns()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        await using var database = await SqliteDatabase.CreateAsync();
        await database.ExecuteAsync(
            "CREATE VIEW endless AS WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c) SELECT x FROM c");
        using var cancel = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        var progress = new LatestRows();
        var export = database.Session.ExportTableAsync(
            new TableName(null, "endless"),
            null,
            null,
            ExportFormat.Csv,
            Beside(database, "endless.csv"),
            progress,
            cancel.Token);

        var waited = Stopwatch.StartNew();
        while (progress.Rows < 2)
        {
            Assert.False(export.IsCompleted, "The export ended before it reported.");
            Assert.True(waited.Elapsed < TimeSpan.FromSeconds(10), "The export reported no rows.");
            await Task.Delay(5, cancellationToken);
        }

        var first = progress.Rows;
        while (progress.Rows == first)
        {
            Assert.True(waited.Elapsed < TimeSpan.FromSeconds(10), "The count stayed where it was.");
            await Task.Delay(5, cancellationToken);
        }

        await cancel.CancelAsync();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => export);
        Assert.True(progress.Rows > first);
    }

    [Fact]
    public async Task SqlInsertOfATableNamesIt()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        await using var database = await SqliteDatabase.CreateAsync();
        var path = Beside(database, "people.sql");

        var rows = await database.Session.ExportTableAsync(
            People, null, null, ExportFormat.SqlInsert, path, cancellationToken: cancellationToken);

        Assert.Equal(3, rows);
        var first = (await File.ReadAllLinesAsync(path, cancellationToken))[0];
        Assert.Equal("INSERT INTO \"people\" (\"id\", \"name\", \"note\") VALUES (1, 'Ada', NULL);", first);
    }

    [Fact]
    public async Task ATableExportWritesEveryRowTheFilterSelectsInTheSortOrder()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        await using var database = await SqliteDatabase.CreateAsync();
        var path = Beside(database, "people.csv");
        var filter = new TableFilter(
            FilterCombinator.And,
            [new FilterRule("name", FilterOperator.NotEqual, new FilterValue.One("Ada"))],
            null);

        var rows = await database.Session.ExportTableAsync(
            People, new ColumnSort(0, false), filter, ExportFormat.Csv, path, cancellationToken: cancellationToken);

        Assert.Equal(2, rows);
        Assert.Equal(
            "id,name,note\n3,Zoë 👋,中文\n2,Grace,\"line one\nline two\"\n",
            await File.ReadAllTextAsync(path, cancellationToken));
    }

    [Fact]
    public async Task ACancelledExportLeavesNoFileBehind()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        await using var database = await SqliteDatabase.CreateAsync();
        await database.ExecuteAsync(
            "CREATE VIEW endless AS WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c) SELECT x FROM c");
        using var cancel = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        var path = Beside(database, "endless.csv");
        var export = database.Session.ExportTableAsync(
            new TableName(null, "endless"), null, null, ExportFormat.Csv, path, cancellationToken: cancel.Token);

        var waited = Stopwatch.StartNew();
        while (Named(database, "endless.csv").Count == 0)
        {
            Assert.False(export.IsCompleted, "The export ended before it wrote anything.");
            Assert.True(waited.Elapsed < TimeSpan.FromSeconds(10), "The export never wrote.");
            await Task.Delay(5, cancellationToken);
        }

        await cancel.CancelAsync();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => export);
        Assert.Empty(Named(database, "endless.csv"));
    }

    private static string Folder(SqliteDatabase database) =>
        Path.GetDirectoryName(database.Path) ?? throw new InvalidOperationException("The database has no folder.");

    private static string Beside(SqliteDatabase database, string name) => Path.Combine(Folder(database), name);

    // The export's own file and its part file, which carries the same name.
    private static List<string> Named(SqliteDatabase database, string part) =>
    [
        .. Directory.EnumerateFiles(Folder(database))
            .Select(file => Path.GetFileName(file))
            .Where(name => name.Contains(part, StringComparison.Ordinal)),
    ];

    // Reported on the thread pool, which a test reads from another thread.
    private sealed class LatestRows : IProgress<long>
    {
        private long _rows;

        public long Rows => Interlocked.Read(ref _rows);

        public void Report(long value) => Interlocked.Exchange(ref _rows, value);
    }
}
