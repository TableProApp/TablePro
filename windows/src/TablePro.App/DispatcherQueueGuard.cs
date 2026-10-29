using Microsoft.UI.Dispatching;
using TablePro.App.Services;

namespace TablePro.App;

/// <summary>
/// Queues UI work so an exception it throws is logged before anything else happens to it. WinUI fails fast on an
/// exception that escapes a dispatcher queue callback, without raising <c>Application.UnhandledException</c>, which
/// left crashes from these callbacks with nothing in errors.log. Every app call site uses these instead of
/// <see cref="DispatcherQueue.TryEnqueue(DispatcherQueueHandler)"/>.
/// </summary>
internal static class DispatcherQueueGuard
{
    public static bool TryEnqueueLogged(this DispatcherQueue queue, DispatcherQueueHandler handler)
    {
        ArgumentNullException.ThrowIfNull(queue);
        ArgumentNullException.ThrowIfNull(handler);
        return queue.TryEnqueue(() => Run(handler));
    }

    public static bool TryEnqueueLogged(this DispatcherQueue queue, DispatcherQueuePriority priority, DispatcherQueueHandler handler)
    {
        ArgumentNullException.ThrowIfNull(queue);
        ArgumentNullException.ThrowIfNull(handler);
        return queue.TryEnqueue(priority, () => Run(handler));
    }

    /// <summary>Runs a callback the dispatcher invokes directly, such as a timer tick, under the same guard.</summary>
    public static void Run(DispatcherQueueHandler handler)
    {
        try
        {
            handler();
        }
        catch (Exception ex) when (Report(ex))
        {
            // Logged and recoverable: the UI thread carries on, as it does after Application.UnhandledException.
        }
    }

    private static bool Report(Exception ex)
    {
        CrashLog.Write("Unhandled exception in a dispatcher callback", ex);
        return CrashLog.IsRecoverable(ex);
    }
}
