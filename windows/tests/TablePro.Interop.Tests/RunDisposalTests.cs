namespace TablePro.Interop.Tests;

// A tab disposes its run when it closes, which can be while the run's events are still read.
public sealed class RunDisposalTests
{
    private const string Endless =
        "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c) SELECT count(*) FROM c";

    [Fact]
    public async Task DisposingARunWhileItsEventsAreReadEndsTheReadingQuietly()
    {
        using var ui = new UiThread();
        await using var database = await SqliteDatabase.CreateAsync();

        await ui.RunAsync(async () =>
        {
            var run = database.Editor.Run(Endless);
            var completion = run.Completion;
            var closing = Task.Run(
                async () =>
                {
                    await Task.Delay(200, CancellationToken.None);
                    ui.Post(run.Dispose);
                },
                CancellationToken.None);
            await foreach (var _ in run.ReadEventsAsync())
            {
            }

            await closing;
            Assert.IsType<QueryOutcome.Cancelled>(await completion);
        });
    }

    [Fact]
    public async Task ADisposedRunAnswersEveryCallWithoutThrowing()
    {
        await using var database = await SqliteDatabase.CreateAsync();
        var run = database.Editor.Run(
            "SELECT name FROM people",
            cancellationToken: TestContext.Current.CancellationToken);
        await run.Completion;

        run.Dispose();
        run.Dispose();
        run.Cancel();

        Assert.Null(run.GetResultSet(0));
        await foreach (var _ in run.ReadEventsAsync(TestContext.Current.CancellationToken))
        {
            Assert.Fail("A disposed run has no events left to read.");
        }
    }

    [Fact]
    public async Task ARunDisposedAtOnceStillCompletes()
    {
        await using var database = await SqliteDatabase.CreateAsync();

        var run = database.Editor.Run(Endless, cancellationToken: TestContext.Current.CancellationToken);
        run.Dispose();

        Assert.IsType<QueryOutcome.Cancelled>(await run.Completion);
    }
}
