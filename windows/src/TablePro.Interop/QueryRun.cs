using System.Runtime.CompilerServices;
using System.Threading.Channels;
using Native = TablePro.Interop.Native;

namespace TablePro.Interop;

/// <summary>A statement running on the core. Disposing it stops the run.</summary>
public sealed class QueryRun : IDisposable
{
    private readonly Native.QueryRun _run;
    private readonly RunWake _wake;
    private int _reading;

    internal QueryRun(Native.QueryRun run, RunWake wake, CancellationToken cancellationToken)
    {
        _run = run;
        _wake = wake;
        Completion = WaitForOutcomeAsync(cancellationToken);
    }

    /// <summary>Completes when the run ends, with how it ended. A refused statement is not an exception.</summary>
    public Task<QueryOutcome> Completion { get; }

    /// <summary>
    /// Every event of the run, in order, ending with <see cref="QueryEvent.Finished"/>. The events are read on
    /// the context that enumerates, so a UI thread applies them itself, and rows that arrive while it is busy
    /// come as one <see cref="QueryEvent.RowsAppended"/>. A run's events can be read once.
    /// </summary>
    public async IAsyncEnumerable<QueryEvent> ReadEventsAsync(
        [EnumeratorCancellation] CancellationToken cancellationToken = default)
    {
        if (Interlocked.Exchange(ref _reading, 1) == 1)
        {
            throw new InvalidOperationException("The run's events are already being read.");
        }

        while (true)
        {
            // Resumes on the caller's context, which is where the events are meant to be read.
            await _wake.WaitAsync(cancellationToken);
            foreach (var native in _run.DrainEvents())
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

    /// <summary>The run's result set at <paramref name="index"/>, from 0, once it has started.</summary>
    public ResultSet? GetResultSet(int index)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(index);
        return _run.ResultSet(checked((uint)index)) is { } set ? new ResultSet(set, index) : null;
    }

    public void Cancel() => _run.Cancel();

    public void Dispose()
    {
        _run.Cancel();
        _run.Dispose();
    }

    private async Task<QueryOutcome> WaitForOutcomeAsync(CancellationToken cancellationToken)
    {
        using var registration = cancellationToken.UnsafeRegister(
            static state => ((Native.QueryRun)state!).Cancel(),
            _run);
        var outcome = await CoreCall.RunAsync(() => _run.Outcome()).ConfigureAwait(false);
        return Mapping.Outcome(outcome);
    }
}

// The core calls it on a runtime thread only when no wake is pending, and a drain clears that, so one slot
// holds every wake a reader has not taken yet.
internal sealed class RunWake : Native.RunListener
{
    private readonly Channel<bool> _signal = Channel.CreateBounded<bool>(
        new BoundedChannelOptions(1)
        {
            FullMode = BoundedChannelFullMode.DropWrite,
            SingleReader = true,
        });

    public void EventsPending() => _signal.Writer.TryWrite(true);

    public ValueTask<bool> WaitAsync(CancellationToken cancellationToken) =>
        _signal.Reader.ReadAsync(cancellationToken);
}
