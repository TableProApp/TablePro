namespace TablePro.Interop.Tests;

// SQLite runs in process, so these always run in CI; the networked engines are covered in Live/SqlEngineTests.
public sealed class QueryPlanTests
{
    [Fact]
    public async Task SqliteOffersOnePrefixExplainVariant()
    {
        await using var database = await SqliteDatabase.CreateAsync();

        var variant = Assert.Single(QueryPlans.VariantsFor(database.Session.EngineId));

        Assert.True(variant.IsSqlPrefix);
        Assert.Equal("sqliteQueryPlan", variant.Format);
        Assert.False(variant.RunsStatement);
    }

    [Fact]
    public async Task ExplainQueryPlanParsesIntoATree()
    {
        await using var database = await SqliteDatabase.CreateAsync();
        var variant = Assert.Single(QueryPlans.VariantsFor(database.Session.EngineId));

        var outcome = await QueryPlans.ExplainAsync(
            database.Editor, variant, "SELECT * FROM people WHERE id > 0",
            cancellationToken: TestContext.Current.CancellationToken);

        var parsed = Assert.IsType<ExplainOutcome.Parsed>(outcome);
        Assert.NotEqual(string.Empty, parsed.Plan.RawText);
        Assert.Contains("people", Operations(parsed.Plan.Root), StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task ARefusedExplainComesBackFailed()
    {
        await using var database = await SqliteDatabase.CreateAsync();
        var variant = Assert.Single(QueryPlans.VariantsFor(database.Session.EngineId));

        var outcome = await QueryPlans.ExplainAsync(
            database.Editor, variant, "SELECT * FROM missing",
            cancellationToken: TestContext.Current.CancellationToken);

        Assert.IsType<ExplainOutcome.Failed>(outcome);
    }

    [Fact]
    public void AMySqlTreePlanParsesThroughTheComposite()
    {
        var plan = QueryPlans.Parse("mysqlComposite", "-> Table scan on people  (cost=1.00 rows=3)");

        Assert.NotNull(plan);
        Assert.Equal("Table scan", plan!.Root.Operation);
        Assert.Equal("people", plan.Root.Relation);
    }

    [Fact]
    public void AnUnparsedFormatReturnsNull() => Assert.Null(QueryPlans.Parse("plainText", "whatever"));

    [Fact]
    public void AnUnknownEngineOffersNoVariants() => Assert.Empty(QueryPlans.VariantsFor("nosuch"));

    private static string Operations(QueryPlanNode node) =>
        node.Children.Aggregate(node.Operation, (text, child) => $"{text} {Operations(child)}");
}
