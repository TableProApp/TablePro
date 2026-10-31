namespace TablePro.Storage.Library;

/// <summary>
/// Runs an action once a burst of signals has been quiet for a delay. A save in an editor or a git checkout fires
/// dozens of file events; rescanning after each would read every file dozens of times.
/// </summary>
internal sealed class DebouncedSignal : IDisposable
{
    private readonly Timer _timer;
    private readonly TimeSpan _delay;
    private bool _disposed;

    public DebouncedSignal(TimeSpan delay, Action action)
    {
        _delay = delay;
        _timer = new Timer(_ => action(), null, Timeout.Infinite, Timeout.Infinite);
    }

    public void Signal()
    {
        lock (_timer)
        {
            if (!_disposed)
            {
                _timer.Change(_delay, Timeout.InfiniteTimeSpan);
            }
        }
    }

    public void Cancel()
    {
        lock (_timer)
        {
            if (!_disposed)
            {
                _timer.Change(Timeout.Infinite, Timeout.Infinite);
            }
        }
    }

    public void Dispose()
    {
        lock (_timer)
        {
            _disposed = true;
            _timer.Dispose();
        }
    }
}
