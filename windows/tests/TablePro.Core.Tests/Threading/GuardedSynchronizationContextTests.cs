using TablePro.Core.Threading;

namespace TablePro.Core.Tests.Threading;

public sealed class GuardedSynchronizationContextTests
{
    [Fact]
    public void ReportsAnExceptionFromAPostedCallbackAndKeepsGoing()
    {
        var reported = new List<Exception>();
        var context = new GuardedSynchronizationContext(new InlineContext(), ex =>
        {
            reported.Add(ex);
            return true;
        });

        context.Post(_ => throw new InvalidOperationException("boom"), null);
        var ranAfter = false;
        context.Post(_ => ranAfter = true, null);

        var error = Assert.Single(reported);
        Assert.Equal("boom", error.Message);
        Assert.True(ranAfter);
    }

    [Fact]
    public void LetsAnExceptionTheReporterRejectsPropagate()
    {
        var reported = 0;
        var context = new GuardedSynchronizationContext(new InlineContext(), _ =>
        {
            reported++;
            return false;
        });

        Assert.Throws<InsufficientExecutionStackException>(() => context.Send(_ => throw new InsufficientExecutionStackException(), null));
        Assert.Equal(1, reported);
    }

    [Fact]
    public void CallbacksRunUnderTheGuardedContextSoContinuationsStayGuarded()
    {
        var context = new GuardedSynchronizationContext(new InlineContext(), _ => true);
        SynchronizationContext? seen = null;

        context.Send(_ => seen = SynchronizationContext.Current, null);

        Assert.Same(context, seen);
        Assert.Same(context, context.CreateCopy());
    }

    [Fact]
    public void AsyncVoidContinuationExceptionsAreReported()
    {
        var reported = new List<Exception>();
        var inline = new InlineContext();
        var context = new GuardedSynchronizationContext(inline, ex =>
        {
            reported.Add(ex);
            return true;
        });
        var previous = SynchronizationContext.Current;
        SynchronizationContext.SetSynchronizationContext(context);
        try
        {
            FireAndForget();
        }
        finally
        {
            SynchronizationContext.SetSynchronizationContext(previous);
        }

        Assert.IsType<NullReferenceException>(Assert.Single(reported));
    }

#pragma warning disable CA2201 // The test throws what a real UI bug threw.
    private static async void FireAndForget()
    {
        await Task.CompletedTask;
        throw new NullReferenceException();
    }
#pragma warning restore CA2201

    /// <summary>Runs posted work at once on the calling thread, like a UI thread with nothing queued.</summary>
    private sealed class InlineContext : SynchronizationContext
    {
        public override void Post(SendOrPostCallback d, object? state) => d(state);

        public override void Send(SendOrPostCallback d, object? state) => d(state);
    }
}
