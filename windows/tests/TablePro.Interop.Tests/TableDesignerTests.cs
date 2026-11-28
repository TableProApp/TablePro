namespace TablePro.Interop.Tests;

public sealed class TableDesignerTests
{
    private static readonly TableName People = new(null, "people");

    [Fact]
    public async Task ANewTableIsCreatedThroughTheDesigner()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        await using var database = await SqliteDatabase.CreateAsync();
        using var designer = await database.Session.OpenTableDesignerAsync(null, cancellationToken: cancellationToken);
        var draft = new TableDraft(
            null,
            "gadgets",
            [Column("id", "INTEGER", primaryKey: true, nullable: false), Column("label", "TEXT", primaryKey: false, nullable: true)],
            [],
            [],
            null);

        var plan = designer.Plan(draft);
        var outcome = await designer.RunAsync(plan, confirmed: true, cancellationToken);

        Assert.Null(plan.Blocked);
        Assert.Equal(SaveGate.Run, plan.Gate);
        Assert.Equal("gadgets", plan.SavedTableName);
        Assert.Contains("CREATE TABLE", plan.Statements[0], StringComparison.OrdinalIgnoreCase);
        Assert.IsType<TableSaveOutcome.Done>(outcome);
        Assert.Equal(["id", "label"], await ColumnNamesAsync(database, "gadgets", cancellationToken));
    }

    [Fact]
    public async Task AColumnAddedInTheDesignerLandsOnTheTable()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        await using var database = await SqliteDatabase.CreateAsync();
        using var designer = await database.Session.OpenTableDesignerAsync(People, cancellationToken: cancellationToken);

        var draft = designer.StartingDraft();
        Assert.Equal(["id", "name", "note"], draft.Columns.Select(column => column.Name));
        var edited = draft with { Columns = [.. draft.Columns, Column("age", "INTEGER", primaryKey: false, nullable: true)] };
        var plan = designer.Plan(edited);
        var outcome = await designer.RunAsync(plan, confirmed: true, cancellationToken);

        Assert.Equal(1, plan.Operations);
        Assert.IsType<TableSaveOutcome.Done>(outcome);
        Assert.Equal(["id", "name", "note", "age"], await ColumnNamesAsync(database, "people", cancellationToken));
    }

    [Fact]
    public async Task APlanRunsOnceAndAStaleOneIsRefused()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        await using var database = await SqliteDatabase.CreateAsync();
        using var designer = await database.Session.OpenTableDesignerAsync(People, cancellationToken: cancellationToken);

        var draft = designer.StartingDraft();
        var edited = draft with { Columns = [.. draft.Columns, Column("tag", "TEXT", primaryKey: false, nullable: true)] };
        var plan = designer.Plan(edited);
        var first = await designer.RunAsync(plan, confirmed: true, cancellationToken);
        var again = await Assert.ThrowsAsync<TableProException>(() => designer.RunAsync(plan, confirmed: true, cancellationToken));

        Assert.IsType<TableSaveOutcome.Done>(first);
        Assert.Equal("designer.already_run", again.Error.Code);
    }

    [Fact]
    public async Task ADefaultTheParserRefusesHoldsTheSave()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        await using var database = await SqliteDatabase.CreateAsync();
        using var designer = await database.Session.OpenTableDesignerAsync(null, cancellationToken: cancellationToken);
        var note = Column("note", "TEXT", primaryKey: false, nullable: true) with { DefaultText = "1 +" };
        var draft = new TableDraft(
            null,
            "loose",
            [Column("id", "INTEGER", primaryKey: true, nullable: false), note],
            [],
            [],
            null);

        var plan = designer.Plan(draft);
        var refused = await Assert.ThrowsAsync<TableProException>(() => designer.RunAsync(plan, confirmed: true, cancellationToken));

        var blocked = Assert.IsType<SaveBlocker.UnparsedDefault>(plan.Blocked);
        Assert.Equal("note", blocked.Column);
        Assert.Equal("designer.unparsed_default", refused.Error.Code);
    }

    private static DraftColumn Column(string name, string typeText, bool primaryKey, bool nullable) =>
        new(null, name, typeText, nullable, primaryKey, AutoIncrement: false, DefaultText: string.Empty, Comment: null, CharacterSet: null, Collation: null);

    private static async Task<IReadOnlyList<string>> ColumnNamesAsync(
        SqliteDatabase database,
        string table,
        CancellationToken cancellationToken)
    {
        var structure = await database.Session.GetStructureAsync(new TableName(null, table), ObjectKind.Table, cancellationToken);
        return [.. structure.Columns.Select(column => column.Name)];
    }
}
