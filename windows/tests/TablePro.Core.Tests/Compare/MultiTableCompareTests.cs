using TablePro.Core.Compare;
using TablePro.Core.Schema;

namespace TablePro.Core.Tests.Compare;

public sealed class MultiTableCompareTests
{
    private static readonly TableStructure Users = InMemoryTableSession.Table("users", ["id"], "id", "name");

    private static readonly TableStructure Orders = InMemoryTableSession.Table("orders", ["id"], "id", "user_id", "total") with
    {
        ForeignKeys = [new ForeignKeyInfo("fk_orders_users", ["user_id"], new ObjectName(null, "users"), ["id"])],
    };

    private static readonly TableStructure Codes = InMemoryTableSession.Table("codes", [], "code", "label");

    private static CancellationToken Token => TestContext.Current.CancellationToken;

    private static ObjectName Name(string name, string? schema = null) => new(schema, name);

    private static TableCompareRequest Request(string table, CompareTableScope? scope = null) =>
        new(new ComparedTablePair(Name(table), Name(table)), scope ?? CompareTableScope.Default);

    [Fact]
    public void PairingMatchesByNameAndSchemaIgnoringCase()
    {
        var pairing = TablePairing.Match(
            [Name("Users", "public"), Name("orders", "public"), Name("audit", "public")],
            [Name("users", "public"), Name("ORDERS", "public"), Name("legacy", "public")]);

        Assert.Equal(["orders", "Users"], pairing.Pairs.Select(p => p.Source.Name));
        Assert.Equal("ORDERS", pairing.Pairs[0].Target.Name);
        Assert.Equal([Name("audit", "public")], pairing.SourceOnly);
        Assert.Equal([Name("legacy", "public")], pairing.TargetOnly);
    }

    [Fact]
    public void PairingCrossesSchemasOnlyWhenTheNameIsUnambiguous()
    {
        var pairing = TablePairing.Match(
            [Name("users", "public"), Name("items", "public")],
            [Name("users", "dbo"), Name("items", "dbo"), Name("items", "archive")]);

        var pair = Assert.Single(pairing.Pairs);
        Assert.Equal(Name("users", "dbo"), pair.Target);
        Assert.Equal([Name("items", "public")], pairing.SourceOnly);
        Assert.Equal(2, pairing.TargetOnly.Count);
    }

    [Fact]
    public void PairNamesBothSidesOnlyWhenTheyDiffer()
    {
        Assert.Equal("users", new ComparedTablePair(Name("users"), Name("USERS")).DisplayName);
        Assert.Equal("users → people", new ComparedTablePair(Name("users"), Name("people")).DisplayName);
    }

    [Fact]
    public async Task EachTableGetsItsOwnOutcomeAndOneProblemDoesNotStopTheRun()
    {
        var source = new InMemoryDatabaseSession(
            new InMemoryTableSession(Users, [[1, "Ann"], [2, "Bob"]]),
            new InMemoryTableSession(Codes, [["a", "A"]]),
            new InMemoryTableSession(Orders, [[10, 1, "5"]]));
        var target = new InMemoryDatabaseSession(
            new InMemoryTableSession(Users, [[1, "Ann"], [3, "Cat"]]),
            new InMemoryTableSession(Codes, [["a", "A"]]));
        var comparer = new MultiTableComparer(source, target);

        var outcomes = await comparer.CompareAllAsync([Request("users"), Request("codes"), Request("orders")], cancellationToken: Token);

        Assert.Equal([TableCompareState.Compared, TableCompareState.Unavailable, TableCompareState.Failed], outcomes.Select(o => o.State));
        var users = outcomes[0].Result!;
        Assert.Equal((1, 1, 0, 1), (users.OnlyInSourceCount, users.OnlyInTargetCount, users.ChangedCount, users.IdenticalCount));
        Assert.True(outcomes[0].CanSync);
        Assert.False(outcomes[1].CanSync);
        Assert.Contains("no primary key", outcomes[1].Problem, StringComparison.Ordinal);
        Assert.Contains("orders", outcomes[2].Problem, StringComparison.Ordinal);
    }

    [Fact]
    public async Task AScopeKeyMakesAKeylessTableComparable()
    {
        var source = new InMemoryDatabaseSession(new InMemoryTableSession(Codes, [["a", "A"], ["b", "B"]]));
        var target = new InMemoryDatabaseSession(new InMemoryTableSession(Codes, [["a", "old"]]));

        var outcome = await new MultiTableComparer(source, target).CompareAsync(Request("codes", new CompareTableScope { KeyColumns = ["code"] }), cancellationToken: Token);

        Assert.Equal(TableCompareState.Compared, outcome.State);
        Assert.Equal((1L, 1L), (outcome.Result!.OnlyInSourceCount, outcome.Result.ChangedCount));
    }

    [Fact]
    public async Task ExcludedColumnsAndRowLimitsComeFromTheTablesScope()
    {
        var source = new InMemoryDatabaseSession(new InMemoryTableSession(Users, [[1, "Ann"], [2, "Bob"], [3, "Cat"]]));
        var target = new InMemoryDatabaseSession(new InMemoryTableSession(Users, [[1, "Anne"], [2, "Bobby"]]));
        var scope = new CompareTableScope { ExcludedColumns = ["name"], RowLimit = 2 };

        var outcome = await new MultiTableComparer(source, target).CompareAsync(Request("users", scope), cancellationToken: Token);

        Assert.Equal(0, outcome.Result!.DifferenceCount);
        Assert.Equal(2, outcome.Result.IdenticalCount);
    }

    [Fact]
    public async Task TablesShareOneBudgetOfKeptDifferences()
    {
        var source = new InMemoryDatabaseSession(
            new InMemoryTableSession(Users, [[1, "a"], [2, "b"], [3, "c"]]),
            new InMemoryTableSession(Orders, [[1, 1, "1"]]));
        var target = new InMemoryDatabaseSession(new InMemoryTableSession(Users, []), new InMemoryTableSession(Orders, []));
        var comparer = new MultiTableComparer(source, target, retainedDifferenceBudget: 2);

        var outcomes = await comparer.CompareAllAsync([Request("users"), Request("orders")], cancellationToken: Token);

        Assert.True(outcomes[0].Result!.IsTruncated);
        Assert.Equal(3, outcomes[0].Result!.OnlyInSourceCount);
        Assert.True(outcomes[1].Result!.IsTruncated);
        Assert.All(outcomes, o => Assert.False(o.CanSync));
    }

    [Fact]
    public async Task CombinedPlanInsertsParentsFirstAndDeletesChildrenFirst()
    {
        var (outcomes, _, _) = await CompareUsersAndOrdersAsync();
        var options = DataCompareOptions.Default with { DeleteExtraRows = true };

        // Given child first, the plan still puts users ahead of orders for inserts and behind them for deletes.
        var plan = CombinedSyncPlan.Build([.. outcomes.Reverse().Select(o => new CombinedSyncInput(o.Result!, null, o.SourceStructure))], options);

        Assert.Equal(
            [("users", SyncStepKind.Insert), ("orders", SyncStepKind.Insert), ("users", SyncStepKind.Update), ("orders", SyncStepKind.Delete), ("users", SyncStepKind.Delete)],
            plan.Segments.Select(s => (s.Table.Name, s.Kind)));
        Assert.Equal((2, 1, 2), (plan.InsertCount, plan.UpdateCount, plan.DeleteCount));
        Assert.Equal(plan.StepCount, plan.Preview(Core.Sql.SqliteDialect.Instance).Count);
    }

    [Fact]
    public async Task CombinedSyncMakesEveryTableMatch()
    {
        var (outcomes, source, target) = await CompareUsersAndOrdersAsync();
        var options = DataCompareOptions.Default with { DeleteExtraRows = true };
        var plan = CombinedSyncPlan.Build([.. outcomes.Select(o => new CombinedSyncInput(o.Result!, null, o.SourceStructure))], options);

        var applied = await DataSyncApplier.ApplyAsync(target, plan, cancellationToken: Token);

        Assert.True(applied.Succeeded);
        Assert.Equal(plan.StepCount, applied.AppliedSteps);
        Assert.Equal(plan.Segments.Count, applied.CommittedBatches);
        var again = await new MultiTableComparer(source, target).CompareAllAsync([Request("users"), Request("orders")], cancellationToken: Token);
        Assert.All(again, o => Assert.Equal(0, o.Result!.DifferenceCount));
    }

    [Fact]
    public async Task AFailedSegmentStopsTheSyncAndKeepsTheSegmentsBeforeIt()
    {
        var (outcomes, _, target) = await CompareUsersAndOrdersAsync();
        var plan = CombinedSyncPlan.Build([.. outcomes.Select(o => new CombinedSyncInput(o.Result!, null, o.SourceStructure))], DataCompareOptions.Default);
        target.FailOnTable = "orders";

        var applied = await DataSyncApplier.ApplyAsync(target, plan, cancellationToken: Token);

        Assert.False(applied.Succeeded);
        Assert.Equal(1, applied.CommittedBatches);
        Assert.Equal(["users", "orders"], target.SavedTables);
        Assert.Contains(target["users"].Rows, r => Equals(r[0], 4));
    }

    [Fact]
    public async Task AFailedSyncNamesEveryTableItSentStatementsTo()
    {
        var (outcomes, _, target) = await CompareUsersAndOrdersAsync();
        var plan = CombinedSyncPlan.Build([.. outcomes.Select(o => new CombinedSyncInput(o.Result!, null, o.SourceStructure))], DataCompareOptions.Default);
        target.FailOnTable = "orders";

        var applied = await DataSyncApplier.ApplyAsync(target, plan, cancellationToken: Token);

        // The failing table counts too: on an engine that ignores ROLLBACK its rows before the failure stay.
        Assert.Equal(["users", "orders"], applied.WrittenTables.Select(t => t.Name));
    }

    [Fact]
    public async Task ASyncThatSucceedsNamesTheTablesItWrote()
    {
        var (outcomes, _, target) = await CompareUsersAndOrdersAsync();
        var plan = CombinedSyncPlan.Build([.. outcomes.Select(o => new CombinedSyncInput(o.Result!, null, o.SourceStructure))], DataCompareOptions.Default);

        var applied = await DataSyncApplier.ApplyAsync(target, plan, cancellationToken: Token);

        Assert.True(applied.Succeeded);
        Assert.Equal(["users", "orders"], applied.WrittenTables.Select(t => t.Name));
    }

    [Fact]
    public async Task ExcludedRowsAndTruncatedTablesStayOutOfTheCombinedPlan()
    {
        var (outcomes, _, _) = await CompareUsersAndOrdersAsync();
        var users = outcomes[0].Result!;
        var skipped = users.Differences.Where(d => d.Kind == RowDiffKind.OnlyInSource).Select(d => users.Spec.KeyIdentity(d.KeyRow)).ToHashSet();
        var truncated = new DataDiffResult { Spec = outcomes[1].Result!.Spec, OnlyInSourceCount = 5, IsTruncated = true, Differences = [] };

        var plan = CombinedSyncPlan.Build([new CombinedSyncInput(users, skipped), new CombinedSyncInput(truncated)], DataCompareOptions.Default);

        var table = Assert.Single(plan.Tables);
        Assert.Equal("users", table.Table.Name);
        Assert.Equal(0, plan.InsertCount);
        Assert.Contains(plan.Warnings, w => w.StartsWith("orders:", StringComparison.Ordinal));
    }

    [Fact]
    public async Task TablesThatReferenceEachOtherAreNamedInAWarning()
    {
        var left = InMemoryTableSession.Table("left", ["id"], "id", "right_id") with { ForeignKeys = [new ForeignKeyInfo("fk_l", ["right_id"], Name("right"), ["id"])] };
        var right = InMemoryTableSession.Table("right", ["id"], "id", "left_id") with { ForeignKeys = [new ForeignKeyInfo("fk_r", ["left_id"], Name("left"), ["id"])] };
        var source = new InMemoryDatabaseSession(new InMemoryTableSession(left, [[1, 1]]), new InMemoryTableSession(right, [[1, 1]]));
        var target = new InMemoryDatabaseSession(new InMemoryTableSession(left, []), new InMemoryTableSession(right, []));
        var outcomes = await new MultiTableComparer(source, target).CompareAllAsync([Request("left"), Request("right")], cancellationToken: Token);

        var plan = CombinedSyncPlan.Build([.. outcomes.Select(o => new CombinedSyncInput(o.Result!, null, o.SourceStructure))], DataCompareOptions.Default);

        Assert.Equal(2, plan.Segments.Count);
        Assert.Contains(plan.Warnings, w => w.Contains("left, right", StringComparison.Ordinal));
    }

    private static async Task<(IReadOnlyList<TableCompareOutcome> Outcomes, InMemoryDatabaseSession Source, InMemoryDatabaseSession Target)> CompareUsersAndOrdersAsync()
    {
        var source = new InMemoryDatabaseSession(
            new InMemoryTableSession(Users, [[1, "Ann"], [2, "Bob"], [4, "Dee"]]),
            new InMemoryTableSession(Orders, [[10, 1, "5"], [11, 4, "7"]]));
        var target = new InMemoryDatabaseSession(
            new InMemoryTableSession(Users, [[1, "Ann"], [2, "Robert"], [3, "Cat"]]),
            new InMemoryTableSession(Orders, [[10, 1, "5"], [12, 3, "9"]]));
        var outcomes = await new MultiTableComparer(source, target).CompareAllAsync([Request("users"), Request("orders")], cancellationToken: Token);
        return (outcomes, source, target);
    }
}
