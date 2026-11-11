namespace TablePro.Interop.Tests;

public sealed class StatementAtTests
{
    [Fact]
    public async Task TheCaretPicksItsOwnStatementAndOnlyThatOneRuns()
    {
        const string Script = "SELECT name FROM people WHERE id = 1; DELETE FROM people";
        await using var database = await SqliteDatabase.CreateAsync();

        var statement = Picked(database.Session, Script, caret: 5);
        using var run = database.Editor.Run(statement ?? string.Empty, cancellationToken: TestContext.Current.CancellationToken);
        var outcome = await run.Completion;
        using var count = database.Editor.Run("SELECT COUNT(*) FROM people", cancellationToken: TestContext.Current.CancellationToken);
        await count.Completion;
        using var counted = count.GetResultSet(0);

        Assert.Equal("SELECT name FROM people WHERE id = 1", statement);
        Assert.Empty(database.Session.GateRun(statement ?? string.Empty).Confirm);
        Assert.IsType<QueryOutcome.Completed>(outcome);
        Assert.Equal("3", counted?.GetCellText(0, 0));
    }

    [Fact]
    public async Task ACaretPastTheLastTerminatorPicksTheLastStatement()
    {
        const string Script = "SELECT 1;\nSELECT 2;\n";
        await using var database = await SqliteDatabase.CreateAsync();

        Assert.Equal("SELECT 2", Picked(database.Session, Script, Script.Length));
    }

    [Fact]
    public async Task ASqliteTriggerBodyIsOneStatement()
    {
        const string Script = "CREATE TRIGGER noted AFTER INSERT ON people BEGIN UPDATE people SET note = 'x'; END; SELECT 1";
        await using var database = await SqliteDatabase.CreateAsync();

        var statement = Picked(database.Session, Script, Script.IndexOf("UPDATE", StringComparison.Ordinal));

        Assert.Equal("CREATE TRIGGER noted AFTER INSERT ON people BEGIN UPDATE people SET note = 'x'; END", statement);
    }

    [Fact]
    public async Task OffsetsCountUtf16UnitsPastAnEmoji()
    {
        const string Script = "SELECT '😀'; SELECT 2";
        await using var database = await SqliteDatabase.CreateAsync();

        var picked = database.Session.StatementAt(Script, Script.IndexOf("SELECT 2", StringComparison.Ordinal) + 1);

        Assert.Equal<Range?>(new Range(13, 21), picked);
        Assert.Equal("SELECT 2", Picked(database.Session, Script, 14));
    }

    [Fact]
    public async Task TextWithNoStatementHasNone()
    {
        await using var database = await SqliteDatabase.CreateAsync();

        Assert.Null(database.Session.StatementAt(string.Empty, 0));
        Assert.Null(database.Session.StatementAt("  -- only a comment\n", 3));
    }

    private static string? Picked(DatabaseSession session, string sql, int caret) =>
        session.StatementAt(sql, caret) is { } range ? sql[range] : null;
}
