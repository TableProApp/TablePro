namespace TablePro.Core.Threading;

/// <summary>
/// Wraps the UI thread's synchronization context so an exception escaping a posted callback, such as the
/// continuation of an <c>async void</c> event handler, reaches <paramref name="report"/> first. WinUI fails fast on an
/// exception thrown from a dispatcher queue callback without raising <c>Application.UnhandledException</c>, so without
/// this the process ends with a stowed exception and nothing in the log.
/// </summary>
/// <param name="inner">The context that actually schedules the work, the dispatcher queue's in the app.</param>
/// <param name="report">
/// Receives the exception and returns true when the app may carry on; false lets it propagate as before, which ends
/// the process.
/// </param>
public sealed class GuardedSynchronizationContext(SynchronizationContext inner, Func<Exception, bool> report) : SynchronizationContext
{
    private readonly SynchronizationContext _inner = inner ?? throw new ArgumentNullException(nameof(inner));
    private readonly Func<Exception, bool> _report = report ?? throw new ArgumentNullException(nameof(report));

    public override void Post(SendOrPostCallback d, object? state)
    {
        ArgumentNullException.ThrowIfNull(d);
        _inner.Post(s => Run(d, s), state);
    }

    public override void Send(SendOrPostCallback d, object? state)
    {
        ArgumentNullException.ThrowIfNull(d);
        _inner.Send(s => Run(d, s), state);
    }

    // Callbacks capture the current context and post back to it; handing out the same instance keeps every
    // continuation guarded.
    public override SynchronizationContext CreateCopy() => this;

    private void Run(SendOrPostCallback d, object? state)
    {
        var previous = Current;
        SetSynchronizationContext(this);
        try
        {
            d(state);
        }
        catch (Exception ex) when (_report(ex))
        {
            // Reported and judged recoverable: the UI thread keeps running, as Application.UnhandledException does
            // with Handled set.
        }
        finally
        {
            SetSynchronizationContext(previous);
        }
    }
}
