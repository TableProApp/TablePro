using TablePro.Core.Compare;
using TablePro.Core.Schema;

namespace TablePro.Core.Tests.Compare;

public sealed class DataDiffEngineTests
{
    private static readonly DataCompareSpec Spec = new(
        new ObjectName(null, "users"),
        new ObjectName("public", "users"),
        [new ComparedColumn("id", "id", IsKey: true), new ComparedColumn("name", "name", IsKey: false), new ComparedColumn("age", "age", IsKey: false)]);

    private static async IAsyncEnumerable<object?[]> Rows(params object?[][] rows)
    {
        foreach (var row in rows)
        {
            await Task.Yield();
            yield return row;
        }
    }

    private static Task<DataDiffResult> Compare(object?[][] source, object?[][] target, DataCompareOptions? options = null) =>
        new DataDiffEngine(Spec, options).CompareAsync(Rows(source), Rows(target), cancellationToken: TestContext.Current.CancellationToken);

    [Fact]
    public async Task ClassifiesEveryKindOfDifference()
    {
        var result = await Compare(
            [[1, "Ann", 30], [2, "Bob", 40], [4, "Dee", 50]],
            [[1L, "Ann", 30L], [2L, "Bobby", 40L], [3L, "Cat", 20L]]);

        Assert.Equal(1, result.IdenticalCount);
        Assert.Equal(1, result.ChangedCount);
        Assert.Equal(1, result.OnlyInSourceCount);
        Assert.Equal(1, result.OnlyInTargetCount);
        Assert.Equal([RowDiffKind.Changed, RowDiffKind.OnlyInTarget, RowDiffKind.OnlyInSource], result.Differences.Select(d => d.Kind));

        var changed = result.Differences[0];
        Assert.Equal([1], changed.ChangedColumns);
        Assert.True(changed.Differs(1));
        Assert.False(changed.Differs(2));
    }

    [Fact]
    public async Task IdenticalTablesHaveNoDifferences()
    {
        var result = await Compare([[1, "a", null], [2, "b", 3]], [[1, "a", null], [2, "b", 3]]);

        Assert.Equal(0, result.DifferenceCount);
        Assert.Equal(2, result.IdenticalCount);
        Assert.Empty(result.Differences);
    }

    [Fact]
    public async Task EmptySidesAreAllOneSided()
    {
        var result = await Compare([[1, "a", 1], [2, "b", 2]], []);

        Assert.Equal(2, result.OnlyInSourceCount);
        Assert.False(result.StoppedAtRowLimit);
    }

    [Fact]
    public async Task DuplicateKeyIsReported()
    {
        var error = await Assert.ThrowsAsync<CompareException>(() => Compare([[1, "a", 1], [1, "b", 2]], []));

        Assert.Contains("more than one row in the source", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task OutOfOrderStreamIsReportedInsteadOfGuessed()
    {
        var error = await Assert.ThrowsAsync<CompareException>(() => Compare([[1, "a", 1]], [[5, "x", 1], [2, "y", 1]]));

        Assert.Contains("sorted rows differently", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task CaseInsensitiveKeysFollowACiCollation()
    {
        var spec = new DataCompareSpec(new(null, "t"), new(null, "t"), [new ComparedColumn("code", "code", IsKey: true), new ComparedColumn("v", "v", IsKey: false)]);
        var options = DataCompareOptions.Default with { KeysIgnoreCase = true };

        var result = await new DataDiffEngine(spec, options).CompareAsync(
            Rows(["alpha", 1], ["Beta", 2]),
            Rows(["ALPHA", 1], ["beta", 2]),
            cancellationToken: TestContext.Current.CancellationToken);

        Assert.Equal(2, result.ChangedCount);
        Assert.All(result.Differences, d => Assert.Equal([0], d.ChangedColumns));
    }

    [Fact]
    public async Task NullKeysAreSkippedAndCounted()
    {
        var result = await Compare([[null, "x", 1], [1, "a", 1]], [[1, "a", 1]]);

        Assert.Equal(1, result.SkippedNullKeyCount);
        Assert.Equal(1, result.IdenticalCount);
    }

    [Fact]
    public async Task RowLimitStopsWithoutCallingTheRestOneSided()
    {
        var options = DataCompareOptions.Default with { RowLimit = 2 };

        var result = await Compare([[1, "a", 1], [2, "b", 1], [3, "c", 1]], [[1, "a", 1], [2, "b", 1], [3, "c", 1]], options);

        Assert.True(result.StoppedAtRowLimit);
        Assert.Equal(2, result.IdenticalCount);
        Assert.Equal(0, result.DifferenceCount);
    }

    [Fact]
    public async Task TableEndingExactlyAtTheLimitIsNotTruncated()
    {
        var options = DataCompareOptions.Default with { RowLimit = 2 };

        var result = await Compare([[1, "a", 1], [2, "b", 1]], [[1, "a", 1], [2, "b", 1]], options);

        Assert.False(result.StoppedAtRowLimit);
    }

    [Fact]
    public async Task RetentionCapKeepsCountsExactAndMarksTruncation()
    {
        var options = DataCompareOptions.Default with { MaxRetainedDifferences = 2 };
        var source = Enumerable.Range(1, 5).Select(i => new object?[] { i, "x", 1 }).ToArray();

        var result = await Compare(source, [], options);

        Assert.Equal(5, result.OnlyInSourceCount);
        Assert.Equal(2, result.Differences.Count);
        Assert.True(result.IsTruncated);
    }

    [Fact]
    public async Task ProgressIsReported()
    {
        var reports = new List<DataCompareProgress>();
        var progress = new SynchronousProgress<DataCompareProgress>(reports.Add);

        await new DataDiffEngine(Spec).CompareAsync(Rows([1, "a", 1]), Rows([1, "a", 1]), progress, TestContext.Current.CancellationToken);

        Assert.Equal(new DataCompareProgress(1, 1, 0), reports[^1]);
    }

    [Fact]
    public async Task CancellationStopsTheWalk()
    {
        using var cancel = new CancellationTokenSource();
        await cancel.CancelAsync();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            new DataDiffEngine(Spec).CompareAsync(Rows([1, "a", 1]), Rows([1, "a", 1]), cancellationToken: cancel.Token));
    }

    [Fact]
    public void SpecNeedsAKey() =>
        Assert.Throws<CompareException>(() => new DataCompareSpec(new(null, "t"), new(null, "t"), [new ComparedColumn("a", "a", IsKey: false)]));

    [Fact]
    public void KeyIdentityKeepsCompositeKeysApart()
    {
        var spec = new DataCompareSpec(new(null, "t"), new(null, "t"), [new ComparedColumn("a", "a", true), new ComparedColumn("b", "b", true)]);

        Assert.NotEqual(spec.KeyIdentity(["a", "b, c"]), spec.KeyIdentity(["a, b", "c"]));
        Assert.Equal("a, b, c", spec.DescribeKey(["a", "b, c"]));
    }

    private sealed class SynchronousProgress<T>(Action<T> report) : IProgress<T>
    {
        public void Report(T value) => report(value);
    }
}
