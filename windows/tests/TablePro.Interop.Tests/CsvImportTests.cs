namespace TablePro.Interop.Tests;

public sealed class CsvImportTests
{
    private static readonly TableName People = new(null, "people");

    [Fact]
    public async Task AFileLandsInTheTableByTheMappingItsHeadersSuggest()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        await using var database = await SqliteDatabase.CreateAsync();
        var file = await WriteAsync(database, "people.csv", "Name,NOTE\nLinus,kernel\nBarbara,\n", cancellationToken);
        using var import = await database.Session.OpenCsvImportAsync(People, cancellationToken);

        var preview = await import.PreviewAsync(file, CsvOptions.Default, cancellationToken);
        var mapping = import.SuggestMapping(preview.Headers);
        var check = await import.PlanAsync(file, CsvOptions.Default, mapping, cancellationToken);
        var ready = Assert.IsType<CsvImportCheck.Ready>(check);
        var outcome = await import.RunAsync(ready, confirmed: false, cancellationToken);
        var again = await Assert.ThrowsAsync<TableProException>(() => import.RunAsync(ready, confirmed: false, cancellationToken));

        Assert.Equal(["id", "name", "note"], import.Columns.Select(column => column.Name));
        Assert.Equal([false, true, true], import.Columns.Select(column => column.TakesEmpty));
        Assert.Equal(["Name", "NOTE"], preview.Headers);
        Assert.Equal(["Linus", "kernel"], preview.Rows[0]);
        Assert.False(preview.Truncated);
        Assert.Equal([null, 0, 1], mapping);
        Assert.Equal(2, ready.Rows);
        Assert.Equal(SaveGate.Run, ready.Gate);
        Assert.NotEmpty(ready.Statements);
        Assert.Equal(new CsvImportOutcome.Imported(2), outcome);
        Assert.Equal("import.not_planned", again.Error.Code);
        Assert.Equal(
            ["Ada", "Grace", "Zoë 👋", "Linus", "Barbara"],
            await ReadAsync(database, "SELECT name FROM people ORDER BY id", cancellationToken));
        Assert.Equal("", (await ReadAsync(database, "SELECT note FROM people WHERE name = 'Barbara'", cancellationToken))[0]);
    }

    [Fact]
    public async Task AFieldTheColumnCannotReadNamesItsLine()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        await using var database = await SqliteDatabase.CreateAsync();
        var file = await WriteAsync(database, "people.tsv", "id\tname\n7\tAda\nseven\tGrace\n", cancellationToken);
        var options = CsvOptions.Default with { Delimiter = CsvDelimiter.Tab };
        using var import = await database.Session.OpenCsvImportAsync(People, cancellationToken);

        var check = await import.PlanAsync(file, options, [0, 1, null], cancellationToken);
        var unplanned = await Assert.ThrowsAsync<TableProException>(
            () => import.RunAsync(new CsvImportCheck.Ready(2, [], SaveGate.Run), confirmed: false, cancellationToken));

        var fault = Assert.IsType<CsvImportCheck.RowRefused>(check).Fault;
        Assert.Equal((3L, "id", "seven"), (fault.Line, fault.Column, fault.Text));
        Assert.StartsWith("edit.", fault.Reason, StringComparison.Ordinal);
        Assert.Equal("import.not_planned", unplanned.Error.Code);
        Assert.Equal(SqliteDatabase.PeopleRows, (await ReadAsync(database, "SELECT id FROM people", cancellationToken)).Count);
    }

    [Fact]
    public async Task ARowTheTableRefusesRollsTheFileBackAndNamesItsLines()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        await using var database = await SqliteDatabase.CreateAsync();
        var file = await WriteAsync(database, "clash.csv", "10,Linus\n1,Taken\n", cancellationToken);
        var options = CsvOptions.Default with { HasHeader = false };
        using var import = await database.Session.OpenCsvImportAsync(People, cancellationToken);

        var preview = await import.PreviewAsync(file, options, cancellationToken);
        var ready = Assert.IsType<CsvImportCheck.Ready>(await import.PlanAsync(file, options, [0, 1, null], cancellationToken));
        var outcome = await import.RunAsync(ready, confirmed: false, cancellationToken);

        Assert.Equal(["", ""], preview.Headers);
        var rolledBack = Assert.IsType<CsvImportOutcome.RolledBack>(outcome);
        Assert.Equal(new LineSpan(1, 2), rolledBack.Lines);
        Assert.Equal(SqliteDatabase.PeopleRows, (await ReadAsync(database, "SELECT id FROM people", cancellationToken)).Count);
    }

    [Fact]
    public async Task AFileThatIsNotTextOrHasNoRowsIsToldApart()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        await using var database = await SqliteDatabase.CreateAsync();
        var binary = Path.Combine(Path.GetDirectoryName(database.Path)!, "binary.csv");
        await File.WriteAllBytesAsync(binary, [(byte)'a', (byte)'\n', 0xff, 0xfe], cancellationToken);
        var headerOnly = await WriteAsync(database, "empty.csv", "id,name\n", cancellationToken);
        using var import = await database.Session.OpenCsvImportAsync(People, cancellationToken);

        var notText = await Assert.ThrowsAsync<TableProException>(() => import.PreviewAsync(binary, CsvOptions.Default, cancellationToken));
        var empty = await import.PlanAsync(headerOnly, CsvOptions.Default, [0, 1, null], cancellationToken);
        var shortMapping = await Assert.ThrowsAsync<TableProException>(
            () => import.PlanAsync(headerOnly, CsvOptions.Default, [0], cancellationToken));

        Assert.Equal("import.not_utf8", notText.Error.Code);
        Assert.Same(CsvImportCheck.Empty.Instance, empty);
        Assert.Equal("import.mapping_invalid", shortMapping.Error.Code);
    }

    private static async Task<string> WriteAsync(
        SqliteDatabase database,
        string name,
        string text,
        CancellationToken cancellationToken)
    {
        var path = Path.Combine(Path.GetDirectoryName(database.Path)!, name);
        await File.WriteAllTextAsync(path, text, cancellationToken);
        return path;
    }

    private static async Task<List<string?>> ReadAsync(SqliteDatabase database, string sql, CancellationToken cancellationToken)
    {
        using var run = database.Editor.Run(sql, cancellationToken: cancellationToken);
        Assert.IsType<QueryOutcome.Completed>(await run.Completion);
        using var set = run.GetResultSet(0) ?? throw new InvalidOperationException("The read held no set.");
        return [.. Enumerable.Range(0, (int)set.RowCount).Select(row => set.GetCellText(row, 0))];
    }
}
