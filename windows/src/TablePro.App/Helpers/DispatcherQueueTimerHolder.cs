using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;

namespace TablePro.App.Helpers;

/// <summary>A restartable one-shot timer on an element's dispatcher, for debouncing work after typing.</summary>
internal sealed class DispatcherQueueTimerHolder
{
    private readonly FrameworkElement _owner;
    private readonly TimeSpan _delay;
    private readonly Action _action;
    private DispatcherQueueTimer? _timer;

    public DispatcherQueueTimerHolder(FrameworkElement owner, TimeSpan delay, Action action)
    {
        _owner = owner;
        _delay = delay;
        _action = action;
    }

    public void Restart()
    {
        if (_timer is null)
        {
            var queue = _owner.DispatcherQueue ?? DispatcherQueue.GetForCurrentThread();
            if (queue is null)
            {
                return;
            }

            _timer = queue.CreateTimer();
            _timer.IsRepeating = false;
            _timer.Interval = _delay;
            _timer.Tick += (_, _) => DispatcherQueueGuard.Run(() => _action());
        }

        _timer.Stop();
        _timer.Start();
    }

    public void Stop() => _timer?.Stop();
}
