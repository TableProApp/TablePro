using System.Runtime.CompilerServices;
using System.Threading.Channels;
using Native = TablePro.Interop.Native;

namespace TablePro.Interop;

public enum AiStop
{
    Complete,

    // The reply reached the token limit and stops mid-way.
    LengthLimit,

    // The model declined to answer.
    Refused,
}

// In order: text as it arrives, then one of Finished, Failed or Stopped.
public abstract record AiReplyEvent
{
    private AiReplyEvent()
    {
    }

    public sealed record Text(string Part) : AiReplyEvent;

    public sealed record Finished(AiStop Stop, long? InputTokens, long? OutputTokens) : AiReplyEvent;

    // An ai.* code, ai.blocked when the connection's policy is Never, or a secret.* one when the key cannot be read.
    public sealed record Failed(CoreError Error) : AiReplyEvent;

    // Cancelled before it ended.
    public sealed record Stopped : AiReplyEvent
    {
        public static Stopped Instance { get; } = new();
    }
}

// Disposing it stops the reply, and its events end where they were read to.
public sealed class AiReply : IDisposable
{
    private readonly Native.AiReply _reply;
    private readonly ReplyWake _wake;
    private readonly Lock _gate = new();
    private bool _disposed;
    private int _reading;

    internal AiReply(Native.AiReply reply, ReplyWake wake)
    {
        _reply = reply;
        _wake = wake;
    }

    // Events arrive on the enumerating context, and text that comes while it is busy as one Text. Read once, so a
    // cancelled read stops the reply too.
    public async IAsyncEnumerable<AiReplyEvent> ReadEventsAsync(
        [EnumeratorCancellation] CancellationToken cancellationToken = default)
    {
        if (Interlocked.Exchange(ref _reading, 1) == 1)
        {
            throw new InvalidOperationException("The reply's events are already being read.");
        }

        using var registration = cancellationToken.UnsafeRegister(static state => ((AiReply)state!).Cancel(), this);

        // Resumes on the caller's context, which is where the events are meant to be read.
        while (await _wake.WaitAsync(cancellationToken))
        {
            if (Drain() is not { } natives)
            {
                yield break;
            }

            foreach (var native in natives)
            {
                var replyEvent = Mapping.ReplyEvent(native);
                yield return replyEvent;
                if (replyEvent is not AiReplyEvent.Text)
                {
                    yield break;
                }
            }
        }
    }

    public void Cancel()
    {
        lock (_gate)
        {
            if (!_disposed)
            {
                _reply.Cancel();
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
            _reply.Cancel();
            _reply.Dispose();
        }

        _wake.Close();
    }

    // Null once disposed. The drain also takes the wake, so the core calls again for the next events.
    private Native.AiReplyEvent[]? Drain()
    {
        lock (_gate)
        {
            if (_disposed)
            {
                return null;
            }

            _wake.Take();
            return _reply.DrainEvents();
        }
    }
}

// The core calls it only when no wake is pending and a drain clears that, so one slot holds every wake not taken.
internal sealed class ReplyWake : Native.AiReplyListener
{
    private readonly Channel<bool> _signal = Channel.CreateBounded<bool>(
        new BoundedChannelOptions(1)
        {
            FullMode = BoundedChannelFullMode.DropWrite,
            SingleReader = true,
        });

    public void EventsPending() => _signal.Writer.TryWrite(true);

    public ValueTask<bool> WaitAsync(CancellationToken cancellationToken) =>
        _signal.Reader.WaitToReadAsync(cancellationToken);

    public void Take() => _signal.Reader.TryRead(out _);

    public void Close() => _signal.Writer.TryComplete();
}
