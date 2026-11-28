namespace TablePro.Interop.Tests;

public sealed class SqlImportTests
{
    [Fact]
    public async Task ASqlFileRunsStatementByStatement()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        await using var database = await SqliteDatabase.CreateAsync();
        var file = await WriteAsync(
            database,
            "seed.sql",
            "CREATE TABLE widgets (id INTEGER PRIMARY KEY, name TEXT);\n" +
            "INSERT INTO widgets VALUES (1, 'Ada');\n" +
            "INSERT INTO widgets VALUES (2, 'Grace');\n",
            cancellationToken);
        var progress = new Collector();

        var report = await database.Session.ImportSqlFileAsync(file, SqlImportOptions.Default, progress, cancellationToken);

        Assert.IsType<SqlImportEnd.Completed>(report.End);
        Assert.Equal(3, report.Statements);
        Assert.Equal(0, report.Failed);
        Assert.Equal(3, progress.Last.Statements);
        Assert.True(progress.Last.BytesRead > 0);
        Assert.Equal(2, await CountAsync(database, "widgets", cancellationToken));
    }

    [Fact]
    public async Task AFailedStatementStopsTheImportUnderStop()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        await using var database = await SqliteDatabase.CreateAsync();
        var file = await WriteAsync(
            database,
            "bad.sql",
            "CREATE TABLE widgets (id INTEGER PRIMARY KEY, name TEXT);\n" +
            "INSERT INTO widgets VALUES (1, 'Ada');\n" +
            "INSERT INTO nope VALUES (2);\n" +
            "INSERT INTO widgets VALUES (3, 'Grace');\n",
            cancellationToken);

        var report = await database.Session.ImportSqlFileAsync(file, SqlImportOptions.Default, cancellationToken: cancellationToken);

        Assert.IsType<SqlImportEnd.Stopped>(report.End);
        Assert.Equal(1, report.Failed);
        var failure = Assert.Single(report.Failures);
        Assert.IsType<SqlImportFault.Statement>(failure.Fault);
        Assert.Equal(1, await CountAsync(database, "widgets", cancellationToken));
    }

    [Fact]
    public async Task ContinueRunsPastAFailedStatement()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        await using var database = await SqliteDatabase.CreateAsync();
        var file = await WriteAsync(
            database,
            "mixed.sql",
            "CREATE TABLE widgets (id INTEGER PRIMARY KEY, name TEXT);\n" +
            "INSERT INTO widgets VALUES (1, 'Ada');\n" +
            "INSERT INTO nope VALUES (2);\n" +
            "INSERT INTO widgets VALUES (3, 'Grace');\n",
            cancellationToken);
        var options = SqlImportOptions.Default with { OnError = SqlImportErrorPolicy.Continue };

        var report = await database.Session.ImportSqlFileAsync(file, options, cancellationToken: cancellationToken);

        Assert.IsType<SqlImportEnd.Completed>(report.End);
        Assert.Equal(1, report.Failed);
        Assert.Equal(2, await CountAsync(database, "widgets", cancellationToken));
    }

    [Fact]
    public async Task AMissingFileIsRefusedWithACode()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        await using var database = await SqliteDatabase.CreateAsync();
        var missing = Path.Combine(Path.GetDirectoryName(database.Path)!, "gone.sql");

        var error = await Assert.ThrowsAsync<TableProException>(
            () => database.Session.ImportSqlFileAsync(missing, SqlImportOptions.Default, cancellationToken: cancellationToken));

        Assert.Equal("sql_import.unreadable", error.Error.Code);
    }

    private static async Task<string> WriteAsync(SqliteDatabase database, string name, string text, CancellationToken cancellationToken)
    {
        var path = Path.Combine(Path.GetDirectoryName(database.Path)!, name);
        await File.WriteAllTextAsync(path, text, cancellationToken);
        return path;
    }

    private static async Task<long> CountAsync(SqliteDatabase database, string table, CancellationToken cancellationToken)
    {
        using var run = database.Editor.Run($"SELECT count(*) FROM {table}", cancellationToken: cancellationToken);
        Assert.IsType<QueryOutcome.Completed>(await run.Completion);
        using var set = run.GetResultSet(0) ?? throw new InvalidOperationException("The read held no set.");
        return long.Parse(set.GetCellText(0, 0)!, System.Globalization.CultureInfo.InvariantCulture);
    }

    private sealed class Collector : IProgress<SqlImportProgress>
    {
        public SqlImportProgress Last { get; private set; }

        public void Report(SqlImportProgress value) => Last = value;
    }
}
