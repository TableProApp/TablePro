using Native = TablePro.Interop.Native;

namespace TablePro.Interop.Tests;

public sealed class ByteLimitTests
{
    private const string Blobs =
        "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 100) " +
        "SELECT x, zeroblob(65536) FROM c";

    [Fact]
    public async Task ARunKeepsWholeRowsUpToItsByteLimit()
    {
        await using var database = await SqliteDatabase.CreateAsync();
        var cancel = TestContext.Current.CancellationToken;

        using var run = database.Editor.Run(Blobs, new QueryOptions(ByteLimit: 1 << 20), cancel);
        var events = new List<QueryEvent>();
        await foreach (var queryEvent in run.ReadEventsAsync(cancel))
        {
            events.Add(queryEvent);
        }

        Assert.IsType<QueryOutcome.Completed>(await run.Completion);
        // Each row is two values and 65,536 bytes, so the 16th crosses 1 MiB and is kept whole.
        var reached = Assert.Single(events.OfType<QueryEvent.ByteLimitReached>());
        Assert.Equal(new QueryEvent.ByteLimitReached(0, 16, 1 << 20), reached);
        var finished = Assert.Single(events.OfType<QueryEvent.ResultSetFinished>());
        Assert.Equal(new QueryEvent.ResultSetFinished(0, 16, 100, Truncation.ByteLimit), finished);
        Assert.True(events.IndexOf(reached) < events.IndexOf(finished));
        using var set = run.GetResultSet(0)!;
        Assert.Equal(2 + (2 * 65_536), set.GetCellText(15, 1)?.Length);
    }

    [Fact]
    public void TheCoresByteLimitEventAndTruncationKeepTheirFields()
    {
        var reached = Mapping.Event(new Native.RunEvent.ByteLimitReached(1, 16, 256_000_000));
        var finished = Mapping.Event(
            new Native.RunEvent.ResultSetFinished(1, 16, null, Native.TruncationTag.ByteLimit));

        Assert.Equal(new QueryEvent.ByteLimitReached(1, 16, 256_000_000), reached);
        Assert.Equal(new QueryEvent.ResultSetFinished(1, 16, null, Truncation.ByteLimit), finished);
        Assert.Equal(256_000_000UL, Mapping.Settings(new QueryOptions(ByteLimit: 256_000_000)).ByteLimit);
        Assert.Null(Mapping.Settings(new QueryOptions()).ByteLimit);
    }

    [Fact]
    public void ATruncationThisBuildDoesNotKnowIsRefused()
    {
        var unknown = new Native.RunEvent.ResultSetFinished(0, 1, 1, (Native.TruncationTag)99);

        Assert.Throws<InvalidOperationException>(() => Mapping.Event(unknown));
    }
}
