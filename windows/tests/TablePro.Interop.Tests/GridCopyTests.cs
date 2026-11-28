namespace TablePro.Interop.Tests;

// Copies a real SQLite result in each format the core renders, through the
// FFI the grid will use (core ADR: grid copy and display text in the core).
public sealed class GridCopyTests
{
    private static readonly long[] AllRows = [0, 1, 2];
    private static readonly int[] AllColumns = [0, 1, 2];

    private static async Task<(SqliteDatabase Database, QueryRun Run, ResultSet Result)> ReadPeopleAsync()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        var database = await SqliteDatabase.CreateAsync();
        var run = database.Editor.Run("SELECT id, name, note FROM people ORDER BY id", cancellationToken: cancellationToken);
        Assert.IsType<QueryOutcome.Completed>(await run.Completion);
        var result = run.GetResultSet(0) ?? throw new InvalidOperationException("The run held no set.");
        return (database, run, result);
    }

    [Fact]
    public async Task CsvCopyCarriesTheCellsAndItsType()
    {
        var (database, run, result) = await ReadPeopleAsync();
        await using var _ = database;
        using var __ = run;
        using var ___ = result;

        var csv = result.Copy(AllRows, AllColumns, GridCopyFormat.Csv);
        var withHeaders = result.Copy(AllRows, AllColumns, GridCopyFormat.CsvWithHeaders);

        Assert.StartsWith("1,Ada,", csv.Text);
        Assert.Contains("3,Zoë 👋,中文", csv.Text);
        Assert.StartsWith("id,name,note", withHeaders.Text);
        Assert.Equal("text/csv", csv.MimeType);
        Assert.NotNull(csv.Cells);
        Assert.Equal(3L, csv.Rows);
        Assert.Equal(0L, csv.Skipped);
    }

    [Fact]
    public async Task TabSeparatedAndJsonAndMarkdownCarryTheirTypes()
    {
        var (database, run, result) = await ReadPeopleAsync();
        await using var _ = database;
        using var __ = run;
        using var ___ = result;

        var tsv = result.Copy(AllRows, AllColumns, GridCopyFormat.Tsv);
        var json = result.Copy(AllRows, AllColumns, GridCopyFormat.Json);
        var markdown = result.Copy(AllRows, AllColumns, GridCopyFormat.Markdown);

        Assert.Contains("1\tAda\t", tsv.Text);
        Assert.Equal("text/tab-separated-values", tsv.MimeType);

        Assert.Contains("\"name\":\"Ada\"", json.Text);
        Assert.Contains("\"note\":null", json.Text);
        Assert.Equal("application/json", json.MimeType);

        Assert.Contains("| id | name | note |", markdown.Text);
        Assert.Equal("text/markdown", markdown.MimeType);
    }

    [Fact]
    public async Task InsertCopyWritesVisibleColumnsForTheConnectedEngine()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        var (database, run, result) = await ReadPeopleAsync();
        await using var _ = database;
        using var __ = run;
        using var ___ = result;

        var insert = database.Session.CopyResultAsInsert(result, AllRows, AllColumns, schema: null, table: "people");

        Assert.Contains("INSERT INTO \"people\" (\"id\", \"name\", \"note\") VALUES (1, 'Ada', NULL)", insert.Text);
        Assert.Equal("application/sql", insert.MimeType);
        Assert.Null(insert.Cells);
        Assert.Equal(3L, insert.Rows);
        Assert.False(string.IsNullOrEmpty(cancellationToken.ToString()));
    }

    [Fact]
    public async Task InClauseAndValuesCopyOneColumnAsLiterals()
    {
        var (database, run, result) = await ReadPeopleAsync();
        await using var _ = database;
        using var __ = run;
        using var ___ = result;

        var inClause = database.Session.CopyResultInClause(result, AllRows, column: 0);
        var values = database.Session.CopyResultAsValues(result, AllRows, [0]);

        Assert.Equal("(1, 2, 3)", inClause.Text);
        Assert.Equal("application/sql", inClause.MimeType);
        Assert.Equal(3L, inClause.Rows);
        Assert.Equal(0L, inClause.Skipped);
        Assert.Equal("1, 2, 3", values.Text);
    }
}
