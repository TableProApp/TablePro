namespace TablePro.Interop.Tests;

public sealed class CatalogChangeTests
{
    private static readonly TableName People = new(null, "people");

    [Fact]
    public async Task ATruncateEmptiesTheTableOnceTheQuestionIsAnswered()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        await using var database = await SqliteDatabase.CreateAsync();
        var abilities = database.Session.CatalogAbilities;

        using var change = database.Session.PlanCatalogChange(
            new CatalogOperation.TruncateTable(People, Cascade: false, RestartIdentity: false, Cluster: null));
        var unanswered = await Assert.ThrowsAsync<TableProException>(
            () => change.RunAsync(confirmed: false, cancellationToken));
        var outcome = await change.RunAsync(confirmed: true, cancellationToken);

        Assert.True(abilities.TruncateTable);
        Assert.True(abilities.TruncateRefusedWhenReferenced);
        Assert.False(abilities.CreateSchema);
        Assert.Equal(["DELETE FROM \"people\""], change.Statements);
        Assert.Equal(SaveGate.Confirm, change.Gate);
        Assert.True(change.IsDestructive);
        Assert.Equal("catalog.not_confirmed", unanswered.Code);
        Assert.IsType<CatalogChangeOutcome.Done>(outcome);
        Assert.Equal("0", await CountAsync(database, "people"));
    }

    [Fact]
    public async Task ADroppedTableLeavesTheCatalogAndTheTablesPointingAtOneAreNamed()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        await using var database = await SqliteDatabase.CreateAsync();
        await database.ExecuteAsync("CREATE TABLE pets (id INTEGER PRIMARY KEY, owner INTEGER REFERENCES people(id))");

        using var keys = await database.Session.ReadTableKeysAsync(People, cancellationToken);
        using var change = database.Session.PlanCatalogChange(new CatalogOperation.DropTable(new(null, "pets"), false));
        var outcome = await change.RunAsync(confirmed: true, cancellationToken);
        var objects = await database.Session.RefreshObjectsAsync(ObjectScope.DefaultSchema, cancellationToken);

        Assert.Equal([new TableName(null, "pets")], keys.ReferencingTables);
        Assert.Equal(["DROP TABLE \"pets\""], change.Statements);
        Assert.IsType<CatalogChangeOutcome.Done>(outcome);
        Assert.DoesNotContain(objects, entry => entry.Name == "pets");
    }

    [Fact]
    public async Task AnOperationTheEngineHasNoSyntaxForIsRefusedBeforeAnythingIsShown()
    {
        await using var database = await SqliteDatabase.CreateAsync();

        var error = Assert.Throws<TableProException>(
            () => database.Session.PlanCatalogChange(new CatalogOperation.CreateSchema("sales", null)));

        Assert.Equal("catalog.unsupported", error.Code);
    }

    private static async Task<string?> CountAsync(SqliteDatabase database, string table)
    {
        using var run = database.Editor.Run($"SELECT count(*) FROM {table}");
        Assert.IsType<QueryOutcome.Completed>(await run.Completion);
        using var set = run.GetResultSet(0) ?? throw new InvalidOperationException("The count held no set.");
        return set.GetCellText(0, 0);
    }
}
