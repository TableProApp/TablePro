using System.Runtime.CompilerServices;
using System.Threading.Channels;
using Native = TablePro.Interop.Native;

namespace TablePro.Interop;

// Disposing it stops the run, and its events end where they were read to.
public sealed class QueryRun : IDisposable
{
    private readonly Native.QueryRun _run;
    private readonly RunWake _wake;
    // A tab can close while its run is read, so no native call starts once Dispose has.
    private readonly Lock _gate = new();
    private bool _disposed;
    private int _reading;

    internal QueryRun(Native.QueryRun run, RunWake wake, CancellationToken cancellationToken)
    {
        _run = run;
        _wake = wake;
        Completion = WaitForOutcomeAsync(cancellationToken);
    }

    // A refused statement completes as Failed, not as an exception.
    public Task<QueryOutcome> Completion { get; }

    // Events arrive on the enumerating context, and rows that come while it is busy as one RowsAppended. Read once.
    public async IAsyncEnumerable<QueryEvent> ReadEventsAsync(
        [EnumeratorCancellation] CancellationToken cancellationToken = default)
    {
        if (Interlocked.Exchange(ref _reading, 1) == 1)
        {
            throw new InvalidOperationException("The run's events are already being read.");
        }

        // Resumes on the caller's context, which is where the events are meant to be read.
        while (await _wake.WaitAsync(cancellationToken))
        {
            if (Drain() is not { } natives)
            {
                yield break;
            }

            foreach (var native in natives)
            {
                var queryEvent = Mapping.Event(native);
                yield return queryEvent;
                if (queryEvent is QueryEvent.Finished)
                {
                    yield break;
                }
            }
        }
    }

    // Null until the set at index, from 0, has started, and once the run is disposed.
    public ResultSet? GetResultSet(int index)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(index);
        lock (_gate)
        {
            if (_disposed)
            {
                return null;
            }

            return _run.ResultSet(checked((uint)index)) is { } set ? new ResultSet(set, index) : null;
        }
    }

    public void Cancel()
    {
        lock (_gate)
        {
            if (!_disposed)
            {
                _run.Cancel();
            }
        }
    }

    public void Dispose()
    {
        lock (_gate)
        {
            if (_disposed)
            {
                return;
            }

            _disposed = true;
            _run.Cancel();
            _run.Dispose();
        }

        _wake.Close();
    }

    // Null once disposed. The drain also takes the wake, so the core calls again for the next events.
    private Native.RunEvent[]? Drain()
    {
        lock (_gate)
        {
            if (_disposed)
            {
                return null;
            }

            _wake.Take();
            return _run.DrainEvents();
        }
    }

    private async Task<QueryOutcome> WaitForOutcomeAsync(CancellationToken cancellationToken)
    {
        using var registration = cancellationToken.UnsafeRegister(static state => ((QueryRun)state!).Cancel(), this);
        return await CoreCall.RunAsync(() => OutcomeAsync()).ConfigureAwait(false);
    }

    // A run disposed before its wait started was stopped by that dispose.
    private async Task<QueryOutcome> OutcomeAsync() =>
        StartOutcome() is { } outcome
            ? Mapping.Outcome(await outcome.ConfigureAwait(false))
            : new QueryOutcome.Cancelled();

    private Task<Native.RunOutcome>? StartOutcome()
    {
        lock (_gate)
        {
            return _disposed ? null : _run.Outcome();
        }
    }
}

// The core calls it only when no wake is pending and a drain clears that, so one slot holds every wake not taken.
internal sealed class RunWake : Native.RunListener
{
    private readonly Channel<bool> _signal = Channel.CreateBounded<bool>(
        new BoundedChannelOptions(1)
        {
            FullMode = BoundedChannelFullMode.DropWrite,
            SingleReader = true,
        });

    public void EventsPending() => _signal.Writer.TryWrite(true);

    // False once the run is disposed and no wake is left.
    public ValueTask<bool> WaitAsync(CancellationToken cancellationToken) =>
        _signal.Reader.WaitToReadAsync(cancellationToken);

    public void Take() => _signal.Reader.TryRead(out _);

    public void Close() => _signal.Writer.TryComplete();
}
