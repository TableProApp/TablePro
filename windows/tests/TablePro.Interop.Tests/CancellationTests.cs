using System.Diagnostics;

namespace TablePro.Interop.Tests;

public sealed class CancellationTests
{
    private const string Endless =
        "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c) SELECT count(*) FROM c";

    [Fact]
    public async Task ATokenStopsTheStatementOnTheEngineAndTheEditorRunsAgain()
    {
        await using var database = await SqliteDatabase.CreateAsync();
        using var cancel = new CancellationTokenSource();

        using var run = database.Editor.Run(Endless, cancellationToken: cancel.Token);
        await Task.Delay(200, TestContext.Current.CancellationToken);
        var asked = Stopwatch.StartNew();
        await cancel.CancelAsync();
        var outcome = await run.Completion;
        var stopped = asked.Elapsed;

        Assert.IsType<QueryOutcome.Cancelled>(outcome);
        Assert.True(stopped < TimeSpan.FromSeconds(5), $"the run ended {stopped} after the cancel");
        await database.ExecuteAsync("SELECT 1");
    }

    [Fact]
    public async Task DisposingARunStopsIt()
    {
        await using var database = await SqliteDatabase.CreateAsync();

        var run = database.Editor.Run(Endless, cancellationToken: TestContext.Current.CancellationToken);
        var completion = run.Completion;
        await Task.Delay(100, TestContext.Current.CancellationToken);
        run.Dispose();

        Assert.IsType<QueryOutcome.Cancelled>(await completion);
    }

    [Fact]
    public async Task TheEventStreamEndsWithTheCancelledOutcome()
    {
        await using var database = await SqliteDatabase.CreateAsync();
        using var cancel = new CancellationTokenSource(TimeSpan.FromMilliseconds(200));
        using var run = database.Editor.Run(Endless, cancellationToken: cancel.Token);

        var last = default(QueryEvent);
        await foreach (var queryEvent in run.ReadEventsAsync(TestContext.Current.CancellationToken))
        {
            last = queryEvent;
        }

        var finished = Assert.IsType<QueryEvent.Finished>(last);
        Assert.IsType<QueryOutcome.Cancelled>(finished.Outcome);
    }

    [Fact]
    public async Task AnAsyncCallWithACancelledTokenThrowsForThatToken()
    {
        await using var database = await SqliteDatabase.CreateAsync();
        using var cancel = new CancellationTokenSource();
        await cancel.CancelAsync();

        var thrown = await Assert.ThrowsAnyAsync<OperationCanceledException>(
            () => database.Session.GetSchemasAsync(cancel.Token));

        Assert.Equal(cancel.Token, thrown.CancellationToken);
    }

    [Fact]
    public async Task ReadingEventsStopsWithTheReadersToken()
    {
        await using var database = await SqliteDatabase.CreateAsync();
        using var run = database.Editor.Run(Endless, cancellationToken: TestContext.Current.CancellationToken);
        using var cancel = new CancellationTokenSource(TimeSpan.FromMilliseconds(200));

        await Assert.ThrowsAnyAsync<OperationCanceledException>(async () =>
        {
            await foreach (var _ in run.ReadEventsAsync(cancel.Token))
            {
            }
        });

        run.Cancel();
        Assert.IsType<QueryOutcome.Cancelled>(await run.Completion);
    }
}
