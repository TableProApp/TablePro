namespace TablePro.App.Model.Tests;

public sealed class TabWorkTests
{
    [Fact]
    public async Task ClosingCancelsTheWorkInFlightAndWaitsForItToEnd()
    {
        var work = new TabWork();
        var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var cleanup = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var ended = false;
        var running = work.RunAsync(async token =>
        {
            started.SetResult();
            try
            {
                await Task.Delay(Timeout.Infinite, token);
            }
            finally
            {
                await cleanup.Task;
                ended = true;
            }
        });
        await started.Task;

        var closing = work.CloseAsync();
        var waited = !closing.IsCompleted;
        cleanup.SetResult();
        await closing;

        Assert.True(waited);
        Assert.True(ended);
        Assert.True(work.IsClosed);
        Assert.False(await running);
    }

    [Fact]
    public async Task WorkAskedForOnceTheTabClosedNeverStarts()
    {
        var work = new TabWork();
        await work.CloseAsync();
        var ran = false;

        var accepted = await work.RunAsync(_ =>
        {
            ran = true;
            return Task.CompletedTask;
        });

        Assert.False(accepted);
        Assert.False(ran);
    }

    [Fact]
    public async Task WorkThatEndsBeforeTheCloseSaysItRan()
    {
        var work = new TabWork();

        var ran = await work.RunAsync(_ => Task.CompletedTask);
        await work.CloseAsync();

        Assert.True(ran);
    }

    [Fact]
    public async Task AFailureTheCloseDidNotCauseStillReachesTheCaller()
    {
        var work = new TabWork();

        await Assert.ThrowsAsync<InvalidOperationException>(
            () => work.RunAsync(_ => throw new InvalidOperationException("broken")));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(
            () => work.RunAsync(_ => throw new OperationCanceledException()));
    }
}
