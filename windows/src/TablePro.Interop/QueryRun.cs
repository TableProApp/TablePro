using System.Runtime.CompilerServices;
using System.Threading.Channels;
using Native = TablePro.Interop.Native;

namespace TablePro.Interop;

// Disposing it stops the run.
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

    // Null until the set at index, from 0, has started.
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

    public ValueTask<bool> WaitAsync(CancellationToken cancellationToken) =>
        _signal.Reader.ReadAsync(cancellationToken);
}
