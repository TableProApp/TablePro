using TablePro.Core.Compare;
using TablePro.Core.Editing;
using TablePro.Core.Schema;
using TablePro.Core.Sql;

namespace TablePro.Core.Tests.Compare;

public sealed class DataSyncTests
{
    private static readonly TableStructure Users = InMemoryTableSession.Table("users", ["id"], "id", "name", "email");

    private static CancellationToken Token => TestContext.Current.CancellationToken;

    private static async Task<(DataDiffResult Result, InMemoryTableSession Source, InMemoryTableSession Target)> CompareAsync(
        object?[][] source, object?[][] target, DataCompareOptions? options = null)
    {
        options ??= DataCompareOptions.Default with { ChunkSize = 2 };
        var sourceSession = new InMemoryTableSession(Users, source);
        var targetSession = new InMemoryTableSession(Users, target);
        var setup = DataCompareSetup.Create(Users, Users);
        var spec = setup.Spec!;
        var result = await new DataDiffEngine(spec, options).CompareAsync(
            SessionRowSource.Source(sourceSession, spec, options, Token),
            SessionRowSource.Target(targetSession, spec, options, Token),
            cancellationToken: Token);
        return (result, sourceSession, targetSession);
    }

    [Fact]
    public async Task ReadsInChunksAndInKeyOrder()
    {
        // Stored out of order: the source sorts on the key, so the walk still sees ascending keys.
        var (result, source, _) = await CompareAsync([[3, "c", null], [1, "a", null], [2, "b", null], [4, "d", null], [5, "e", null]], []);

        Assert.Equal(5, result.OnlyInSourceCount);
        Assert.Equal([1, 2, 3, 4, 5], result.Differences.Select(d => (int)d.Source![0]!));
        Assert.Equal(3, source.BrowseCalls);
    }

    [Fact]
    public async Task SyncMakesTheTargetMatchTheSource()
    {
        var (result, source, target) = await CompareAsync(
            [[1, "Ann", "ann@x"], [2, "Bob", "bob@new"], [4, "Dee", null]],
            [[1, "Ann", "ann@x"], [2, "Bob", "bob@old"], [3, "Cat", "cat@x"]]);
        var options = DataCompareOptions.Default with { DeleteExtraRows = true };

        var plan = DataSyncPlan.Build(result, options);
        Assert.Equal((1, 1, 1), (plan.InsertCount, plan.UpdateCount, plan.DeleteCount));
        Assert.Equal([SyncStepKind.Insert, SyncStepKind.Update, SyncStepKind.Delete], plan.Steps.Select(s => s.Kind));

        var applied = await DataSyncApplier.ApplyAsync(target, plan, cancellationToken: Token);
        Assert.True(applied.Succeeded);
        Assert.Equal(3, applied.RowsAffected);

        var (again, _, _) = await CompareAsync([.. source.Rows], [.. target.Rows]);
        Assert.Equal(0, again.DifferenceCount);
    }

    [Fact]
    public async Task DeletesAreOffByDefault()
    {
        var (result, _, _) = await CompareAsync([[1, "a", null]], [[1, "a", null], [2, "b", null]]);

        var plan = DataSyncPlan.Build(result, DataCompareOptions.Default);

        Assert.True(plan.IsEmpty);
    }

    [Fact]
    public async Task UpdateSetsOnlyTheChangedColumnsAndKeysOnTheTarget()
    {
        var (result, _, _) = await CompareAsync([[1, "Ann", "new"]], [[1, "Ann", "old"]]);

        var update = Assert.IsType<RowUpdate>(Assert.Single(DataSyncPlan.Build(result, DataCompareOptions.Default).Steps).Change);

        Assert.Equal(["email"], update.Values.Keys);
        Assert.Equal("new", update.Values["email"]);
        Assert.Equal(1, update.Key["id"]);
    }

    [Fact]
    public async Task InsertWritesNullsExplicitly()
    {
        var (result, _, _) = await CompareAsync([[1, "Ann", null]], []);

        var insert = Assert.IsType<RowInsert>(Assert.Single(DataSyncPlan.Build(result, DataCompareOptions.Default).Steps).Change);

        Assert.True(insert.Values.ContainsKey("email"));
        Assert.Null(insert.Values["email"]);
    }

    [Fact]
    public async Task ExcludedRowsAreLeftOut()
    {
        var (result, _, _) = await CompareAsync([[1, "a", null], [2, "b", null]], []);
        var excluded = new HashSet<string> { result.Spec.KeyIdentity(result.Differences[0].KeyRow) };

        var plan = DataSyncPlan.Build(result, DataCompareOptions.Default, excluded);

        Assert.Equal("2", Assert.Single(plan.Steps).Key);
    }

    [Fact]
    public async Task TruncatedComparisonCannotBeSynced()
    {
        var options = DataCompareOptions.Default with { MaxRetainedDifferences = 1 };
        var (result, _, _) = await CompareAsync([[1, "a", null], [2, "b", null]], [], options);

        Assert.Throws<CompareException>(() => DataSyncPlan.Build(result, options));
    }

    [Fact]
    public async Task PreviewWritesValuesIn()
    {
        var (result, _, _) = await CompareAsync([[1, "O'Brien", null]], []);

        var preview = Assert.Single(DataSyncPlan.Build(result, DataCompareOptions.Default).Preview(SqliteDialect.Instance));

        Assert.Equal("INSERT INTO \"users\" (\"id\", \"name\", \"email\") VALUES (1, 'O''Brien', NULL)", preview);
    }

    [Fact]
    public async Task SingleTransactionFailureLeavesTheTargetUnchanged()
    {
        var (result, _, target) = await CompareAsync([[1, "a", null], [2, "b", null]], []);
        var plan = DataSyncPlan.Build(result, DataCompareOptions.Default);
        target.FailOnSaveCall = 1;

        var applied = await DataSyncApplier.ApplyAsync(target, plan, cancellationToken: Token);

        Assert.False(applied.Succeeded);
        Assert.Equal(0, applied.CommittedBatches);
        Assert.Empty(target.Rows);
    }

    [Fact]
    public async Task BatchesCommitAsTheyGoAndStopAtAFailure()
    {
        var (result, _, target) = await CompareAsync([[1, "a", null], [2, "b", null], [3, "c", null]], []);
        var plan = DataSyncPlan.Build(result, DataCompareOptions.Default);
        target.FailOnSaveCall = 2;
        var progress = new List<DataSyncProgress>();

        var applied = await DataSyncApplier.ApplyAsync(target, plan, new DataSyncApplyOptions(BatchSize: 2, SingleTransaction: false), new Progress(progress.Add), Token);

        Assert.False(applied.Succeeded);
        Assert.Equal((1, 2, 2), (applied.CommittedBatches, applied.TotalBatches, applied.AppliedSteps));
        Assert.Equal(2, target.Rows.Count);
        Assert.Equal(new DataSyncProgress(2, 3), progress[^1]);
    }

    [Fact]
    public async Task KeyedChangeThatHitsNoRowRollsBack()
    {
        var (result, _, target) = await CompareAsync([[1, "a", "new"]], [[1, "a", "old"]]);
        var plan = DataSyncPlan.Build(result, DataCompareOptions.Default);
        target.Rows.Clear();

        var applied = await DataSyncApplier.ApplyAsync(target, plan, cancellationToken: Token);

        Assert.IsType<RowCountMismatchException>(applied.Error);
    }

    [Fact]
    public void SetupMatchesColumnsByNameAndListsTheRest()
    {
        var source = InMemoryTableSession.Table("t", ["ID"], "ID", "name", "only_source");
        var target = InMemoryTableSession.Table("t", ["id"], "id", "NAME", "only_target");

        var setup = DataCompareSetup.Create(source, target);

        Assert.Null(setup.Problem);
        Assert.Equal(["ID", "name"], setup.Spec!.SourceColumnNames);
        Assert.Equal(["id", "NAME"], setup.Spec.TargetColumnNames);
        Assert.Equal(["only_source"], setup.SourceOnlyColumns);
        Assert.Equal(["only_target"], setup.TargetOnlyColumns);
    }

    [Fact]
    public void SetupWithoutAKeyExplainsWhy()
    {
        var table = InMemoryTableSession.Table("t", [], "a", "b");

        var setup = DataCompareSetup.Create(table, table);

        Assert.Null(setup.Spec);
        Assert.Contains("no primary key", setup.Problem, StringComparison.Ordinal);
        Assert.NotNull(DataCompareSetup.Create(table, table, keyColumns: ["b"]).Spec);
    }

    [Fact]
    public void SetupPutsKeysFirstAndLeavesExcludedColumnsOut()
    {
        var table = InMemoryTableSession.Table("t", ["id"], "name", "updated_at", "id");

        var spec = DataCompareSetup.Create(table, table, excludedColumns: ["updated_at", "id"]).Spec!;

        Assert.Equal(["id", "name"], spec.SourceColumnNames);
    }

    [Fact]
    public void RollbackSupportIsKnownPerEngine()
    {
        Assert.True(DataSyncTransactionality.CanRollBack(Core.Connections.DatabaseEngine.PostgreSql));
        Assert.False(DataSyncTransactionality.CanRollBack(Core.Connections.DatabaseEngine.ClickHouse));
    }

    private sealed class Progress(Action<DataSyncProgress> report) : IProgress<DataSyncProgress>
    {
        public void Report(DataSyncProgress value) => report(value);
    }
}
