namespace TablePro.Interop.Tests;

public sealed class DatabaseDumpTests
{
    [Fact]
    public async Task ADatabaseDumpWritesItsStructureAndRows()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        await using var database = await SqliteDatabase.CreateAsync();
        var path = Beside(database, "dump.sql");
        var progress = new Collector();

        var report = await database.Session.DumpDatabaseAsync(
            DumpScope.Database.Instance, data: true, path, gzip: false, progress, cancellationToken);

        var text = await File.ReadAllTextAsync(path, cancellationToken);
        Assert.Equal(1, report.Tables);
        Assert.Equal(SqliteDatabase.PeopleRows, report.Rows);
        Assert.Equal(SqliteDatabase.PeopleRows, progress.Last.Rows);
        Assert.Contains("CREATE TABLE", text, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("'Ada'", text, StringComparison.Ordinal);
    }

    [Fact]
    public async Task AStructureOnlyDumpLeavesTheRowsOut()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        await using var database = await SqliteDatabase.CreateAsync();
        var path = Beside(database, "schema.sql");

        var report = await database.Session.DumpDatabaseAsync(
            DumpScope.Database.Instance, data: false, path, cancellationToken: cancellationToken);

        var text = await File.ReadAllTextAsync(path, cancellationToken);
        Assert.Equal(0, report.Rows);
        Assert.Contains("CREATE TABLE", text, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("'Ada'", text, StringComparison.Ordinal);
    }

    [Fact]
    public async Task AGzippedDumpIsWrittenGzip()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        await using var database = await SqliteDatabase.CreateAsync();
        var path = Beside(database, "dump.sql.gz");

        await database.Session.DumpDatabaseAsync(
            DumpScope.Database.Instance, data: true, path, gzip: true, cancellationToken: cancellationToken);

        var bytes = await File.ReadAllBytesAsync(path, cancellationToken);
        Assert.Equal([0x1f, 0x8b], bytes[..2]);
    }

    [Fact]
    public async Task ADumpReloadsIntoAnEmptyDatabase()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        await using var source = await SqliteDatabase.CreateAsync();
        var path = Beside(source, "dump.sql");
        await source.Session.DumpDatabaseAsync(
            DumpScope.Database.Instance, data: true, path, cancellationToken: cancellationToken);

        await using var target = await SqliteDatabase.CreateAsync();
        await target.ExecuteAsync("DROP TABLE people");
        var report = await target.Session.ImportSqlFileAsync(path, SqlImportOptions.Default, cancellationToken: cancellationToken);

        Assert.IsType<SqlImportEnd.Completed>(report.End);
        Assert.Equal(0, report.Failed);
        Assert.Equal(SqliteDatabase.PeopleRows, await CountAsync(target, "people", cancellationToken));
    }

    private static string Beside(SqliteDatabase database, string name) =>
        Path.Combine(Path.GetDirectoryName(database.Path)!, name);

    private static async Task<long> CountAsync(SqliteDatabase database, string table, CancellationToken cancellationToken)
    {
        using var run = database.Editor.Run($"SELECT count(*) FROM {table}", cancellationToken: cancellationToken);
        Assert.IsType<QueryOutcome.Completed>(await run.Completion);
        using var set = run.GetResultSet(0) ?? throw new InvalidOperationException("The read held no set.");
        return long.Parse(set.GetCellText(0, 0)!, System.Globalization.CultureInfo.InvariantCulture);
    }

    private sealed class Collector : IProgress<DumpProgress>
    {
        public DumpProgress Last { get; private set; }

        public void Report(DumpProgress value) => Last = value;
    }
}
