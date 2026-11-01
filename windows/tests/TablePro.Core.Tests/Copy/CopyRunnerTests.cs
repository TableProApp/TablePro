using TablePro.Core.Connections;
using TablePro.Core.Copy;
using TablePro.Core.Schema;
using TablePro.Core.Tests.Generation;

namespace TablePro.Core.Tests.Copy;

public sealed class CopyRunnerTests
{
    private static CancellationToken Token => TestContext.Current.CancellationToken;

    /// <summary>A shop whose orders reference customers and whose employees reference themselves, with a row for each.</summary>
    private static FakeSession Source(DatabaseEngine engine = DatabaseEngine.PostgreSql)
    {
        var source = new FakeSession(engine);
        source.AddTable("customers", [("id", "integer", typeof(int)), ("name", "character varying(40)", typeof(string))], primaryKey: ["id"]);
        source.AddTable(
            "orders",
            [("id", "integer", typeof(int)), ("customer_id", "integer", typeof(int)), ("token", "uuid", typeof(Guid))],
            primaryKey: ["id"],
            keys: [FakeSession.Key("orders_customer_fk", "customer_id", "customers", "id"), FakeSession.Key("orders_region_fk", "customer_id", "regions", "id", schema: "geo")],
            indexes: [new IndexInfo("orders_customer_ix", ["customer_id"], false, false), new IndexInfo("orders_pkey", ["id"], true, true)]);
        source.AddTable("employees", [("id", "integer", typeof(int)), ("boss_id", "integer", typeof(int))], primaryKey: ["id"], keys: [FakeSession.Key("boss_fk", "boss_id", "employees", "id")]);
        for (var i = 1; i <= 12; i++)
        {
            source.Insert("customers", [i, $"Customer {i}"]);
        }

        for (var i = 1; i <= 30; i++)
        {
            source.Insert("orders", [i, (i % 12) + 1, Guid.NewGuid()]);
        }

        // The first employee's boss comes later, so the rows break the key until the last one is in.
        source.Insert("employees", [1, 3], [2, 1], [3, null]);
        return source;
    }

    private static DatabaseObject Table(string name) => new(new ObjectName("public", name), ObjectKind.Table);

    private static CopyRequest Request(FakeSession source, FakeSession target, CopyExistingPolicy policy = CopyExistingPolicy.Skip, CopyContent content = CopyContent.StructureAndData, CopyErrorHandling errors = CopyErrorHandling.Stop, params string[] tables) =>
        new(source, [.. (tables.Length == 0 ? ["orders", "employees", "customers"] : tables).Select(Table)], target, "public", content, policy, errors) { BatchSize = 5 };

    [Fact]
    public async Task PlansParentsFirstAndKeepsOnlyKeysTheTargetCanHave()
    {
        var plan = await CopyPlanner.PlanAsync(Request(Source(), new FakeSession(DatabaseEngine.MySql)), Token);

        // The first table whose parents are all placed goes next; a key to the table itself never holds it back.
        Assert.Equal(["employees", "customers", "orders"], plan.Tables.Select(t => t.Target.Name));
        Assert.True(plan.CrossesEngines);
        var orders = plan.Tables[2];
        Assert.Equal(CopyAction.Create, orders.Action);
        Assert.Equal(["orders_customer_fk"], orders.ForeignKeys.Select(k => k.Name));
        Assert.Contains(orders.Notes, n => n.Contains("orders_region_fk", StringComparison.Ordinal));
        Assert.Equal(["orders_customer_ix"], orders.Indexes.Select(i => i.Name));
        Assert.Equal(["INT", "INT", "CHAR(36)"], orders.Columns.Select(c => c.DataType));
        Assert.Equal(["id"], orders.PageOrder);
    }

    [Fact]
    public async Task CopiesRowsInBatchesAndAddsKeysOnceEveryRowIsIn()
    {
        var source = Source();
        var target = new FakeSession(DatabaseEngine.PostgreSql);
        var request = Request(source, target);
        var plan = await CopyPlanner.PlanAsync(request, Token);
        var progress = new List<CopyProgress>();

        var result = await CopyRunner.RunAsync(request, plan, new RowGenerationRunTests.SyncProgress<CopyProgress>(progress.Add), Token);

        Assert.True(result.Succeeded, string.Join("; ", result.Outcomes.Select(o => $"{o.Name}: {o.Error}")));
        Assert.Equal(45, result.RowsCopied);
        Assert.Equal(30, target.Tables[new ObjectName("public", "orders")].Rows.Count);
        Assert.Equal([3, 5, 5, 2, 5, 5, 5, 5, 5, 5], target.SavedBatches);
        Assert.Equal(["boss_fk"], target.Tables[new ObjectName("public", "employees")].Structure.ForeignKeys.Select(k => k.Name));

        // Every key comes after the last row, which is what lets the self-referencing employees in.
        var lastInsertPhase = progress.FindLastIndex(p => p.Phase == CopyPhase.CopyingRows);
        Assert.True(progress.FindIndex(p => p.Phase == CopyPhase.LinkingKeys) > lastInsertPhase);
        Assert.Equal(CopyPhase.Finished, progress[^1].Phase);
    }

    [Fact]
    public async Task ACrossEngineCopyConvertsValuesTheTargetCannotBind()
    {
        var source = Source();
        var target = new FakeSession(DatabaseEngine.Sqlite, schema: null);
        var request = Request(source, target, tables: ["customers", "orders"]) with { TargetSchema = null };

        var result = await CopyRunner.RunAsync(request, await CopyPlanner.PlanAsync(request, Token), null, Token);

        Assert.True(result.Succeeded);
        Assert.All(target.Tables[new ObjectName(null, "orders")].Rows, r => Assert.IsType<string>(r["token"]));
    }

    [Fact]
    public async Task ARowThatBreaksAKeyFailsItsTableWhenTheKeyIsAdded()
    {
        var source = Source();
        source.Insert("orders", [99, 404, Guid.NewGuid()]);
        var target = new FakeSession(DatabaseEngine.PostgreSql);
        var request = Request(source, target, errors: CopyErrorHandling.SkipAndContinue);

        var result = await CopyRunner.RunAsync(request, await CopyPlanner.PlanAsync(request, Token), null, Token);

        var orders = result.Outcomes.Single(o => o.Name == "public.orders");
        Assert.Equal(CopyOutcomeStatus.Failed, orders.Status);
        Assert.Contains("orders_customer_fk", orders.Error, StringComparison.Ordinal);
        Assert.Equal(31, orders.RowsCopied);
        Assert.Equal(CopyOutcomeStatus.Copied, result.Outcomes.Single(o => o.Name == "public.employees").Status);
    }

    [Fact]
    public async Task StopEndsTheRunAtTheFirstFailure()
    {
        var source = Source();
        var target = new FakeSession(DatabaseEngine.PostgreSql) { RejectInsert = (table, _) => table.Name == "orders" };
        var request = Request(source, target);

        var result = await CopyRunner.RunAsync(request, await CopyPlanner.PlanAsync(request, Token), null, Token);

        Assert.False(result.Succeeded);
        Assert.Equal(CopyOutcomeStatus.Failed, result.Outcomes.Single(o => o.Name == "public.orders").Status);
        // Customers and employees were finished before orders failed; nothing after the failure ran.
        Assert.Equal(CopyOutcomeStatus.Copied, result.Outcomes.Single(o => o.Name == "public.customers").Status);
        Assert.Equal(CopyOutcomeStatus.Skipped, result.Outcomes.Single(o => o.Name == "public.employees").Status);
        Assert.Equal(3, target.Tables[new ObjectName("public", "employees")].Rows.Count);
        Assert.Empty(target.Tables[new ObjectName("public", "employees")].Structure.ForeignKeys);
    }

    [Fact]
    public async Task AnExistingTableIsSkippedReplacedOrFilled()
    {
        var source = Source();
        var target = new FakeSession(DatabaseEngine.PostgreSql);
        target.AddTable("customers", [("id", "integer", typeof(int)), ("name", "text", typeof(string)), ("extra", "text", typeof(string))], primaryKey: ["id"]);
        target.Insert("customers", [100, "Kept", "x"]);

        var skip = await CopyPlanner.PlanAsync(Request(source, target, tables: ["customers"]), Token);
        Assert.Equal(CopyAction.Skip, skip.Tables[0].Action);

        var append = Request(source, target, CopyExistingPolicy.AppendData, tables: ["customers"]);
        var appended = await CopyRunner.RunAsync(append, await CopyPlanner.PlanAsync(append, Token), null, Token);
        Assert.Equal(12, appended.RowsCopied);
        Assert.Equal(13, target.Tables[new ObjectName("public", "customers")].Rows.Count);

        var replace = Request(source, target, CopyExistingPolicy.Replace, CopyContent.Data, tables: ["customers"]);
        await CopyRunner.RunAsync(replace, await CopyPlanner.PlanAsync(replace, Token), null, Token);
        Assert.Equal(12, target.Tables[new ObjectName("public", "customers")].Rows.Count);
        Assert.Contains(target.Executed, s => s.StartsWith("TruncateTable", StringComparison.Ordinal));

        var recreate = Request(source, target, CopyExistingPolicy.Replace, tables: ["customers"]);
        await CopyRunner.RunAsync(recreate, await CopyPlanner.PlanAsync(recreate, Token), null, Token);
        Assert.DoesNotContain(target.Tables[new ObjectName("public", "customers")].Structure.Columns, c => c.Name == "extra");
    }

    [Fact]
    public async Task CancellingStopsBetweenBatchesAndSaysSo()
    {
        var source = Source();
        using var cancellation = new CancellationTokenSource();
        var target = new FakeSession(DatabaseEngine.PostgreSql) { CancelAfterFirstBatch = cancellation };
        var request = Request(source, target);

        var result = await CopyRunner.RunAsync(request, await CopyPlanner.PlanAsync(request, Token), null, cancellation.Token);

        Assert.True(result.Cancelled);
        Assert.Equal([3], target.SavedBatches);
        Assert.Contains(result.Outcomes, o => o.Status == CopyOutcomeStatus.Cancelled);
    }

    [Fact]
    public async Task ViewsAreCopiedIntoTheTargetSchemaAndNotAcrossEngines()
    {
        var source = Source();
        var view = new DatabaseObject(new ObjectName("public", "big_orders"), ObjectKind.View);
        source.Definitions[view.Name] = (view, "CREATE VIEW public.big_orders AS SELECT * FROM public.orders WHERE id > 10;");
        var target = new FakeSession(DatabaseEngine.PostgreSql, "archive");
        var request = new CopyRequest(source, [Table("orders"), Table("customers"), view], target, "archive");

        var result = await CopyRunner.RunAsync(request, await CopyPlanner.PlanAsync(request, Token), null, Token);

        Assert.True(result.Succeeded);
        Assert.Contains("CREATE VIEW \"archive\".big_orders AS SELECT * FROM \"archive\".orders WHERE id > 10", target.Executed);

        var mysql = await CopyPlanner.PlanAsync(request with { Target = new FakeSession(DatabaseEngine.MySql) }, Token);
        Assert.Equal(CopyAction.Skip, mysql.Definitions[0].Action);
    }

    [Fact]
    public async Task IdentityColumnsAreMovedPastTheCopiedRowsOnPostgres()
    {
        var source = new FakeSession(DatabaseEngine.MySql, schema: null);
        source.Tables[new ObjectName(null, "items")] = new FakeTable(
            new TableStructure(new ObjectName(null, "items"), [new ColumnInfo("id", "int", false, null, true, true, 0)], [], [], []),
            new Dictionary<string, Type> { ["id"] = typeof(int) });
        source.Insert("items", [1], [2]);
        var target = new FakeSession(DatabaseEngine.PostgreSql);
        var request = new CopyRequest(source, [new DatabaseObject(new ObjectName(null, "items"), ObjectKind.Table)], target, "public");

        var result = await CopyRunner.RunAsync(request, await CopyPlanner.PlanAsync(request, Token), null, Token);

        Assert.True(result.Succeeded);
        Assert.Contains(target.Executed, s => s.StartsWith("SELECT setval(pg_get_serial_sequence('\"public\".\"items\"', 'id')", StringComparison.Ordinal));
    }

    [Fact]
    public async Task ARefusedEnginePairPlansNothing()
    {
        var plan = await CopyPlanner.PlanAsync(Request(Source(), new FakeSession(DatabaseEngine.Snowflake)), Token);

        Assert.True(plan.IsEmpty);
        Assert.Single(plan.Warnings);
    }

    [Fact]
    public void AKeylessTableIsPagedByEverySortableColumn()
    {
        var structure = new TableStructure(
            new ObjectName("public", "log"),
            [new ColumnInfo("at", "timestamp", true, null, false, false, 0), new ColumnInfo("body", "jsonb", true, null, false, false, 1), new ColumnInfo("level", "integer", true, null, false, false, 2)],
            [],
            [],
            []);

        Assert.Equal(["at", "level"], CopyPlanner.PageOrder(structure, DatabaseEngine.PostgreSql));
    }
}
