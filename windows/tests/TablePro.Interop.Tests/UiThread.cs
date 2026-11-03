using System.Collections.Concurrent;

namespace TablePro.Interop.Tests;

// One thread with a SynchronizationContext, as a WinUI DispatcherQueue gives the app's UI thread.
internal sealed class UiThread : IDisposable
{
    private readonly BlockingCollection<(SendOrPostCallback Callback, object? State)> _queue = [];
    private readonly Thread _thread;

    public UiThread()
    {
        _thread = new Thread(Loop) { IsBackground = true, Name = "ui" };
        _thread.Start();
    }

    public int ThreadId => _thread.ManagedThreadId;

    public bool IsCurrent => Environment.CurrentManagedThreadId == ThreadId;

    public Task RunAsync(Func<Task> work)
    {
        var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        Post(async () =>
        {
            try
            {
                await work();
                done.SetResult();
            }
            catch (Exception exception)
            {
                done.SetException(exception);
            }
        });
        return done.Task;
    }

    public void Post(Action action) => _queue.Add((static state => ((Action)state!)(), action));

    public void Dispose()
    {
        _queue.CompleteAdding();
        _thread.Join();
        _queue.Dispose();
    }

    private void Loop()
    {
        SynchronizationContext.SetSynchronizationContext(new Context(this));
        foreach (var (callback, state) in _queue.GetConsumingEnumerable())
        {
            callback(state);
        }
    }

    private sealed class Context(UiThread thread) : SynchronizationContext
    {
        public override void Post(SendOrPostCallback d, object? state) => thread._queue.Add((d, state));

        public override void Send(SendOrPostCallback d, object? state) =>
            throw new NotSupportedException("A UI thread is never blocked on.");

        public override SynchronizationContext CreateCopy() => this;
    }
}
