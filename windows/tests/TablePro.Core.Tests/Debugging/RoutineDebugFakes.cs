using System.Collections.Concurrent;
using System.Threading.Channels;
using TablePro.Core.Drivers;
using TablePro.Core.Schema;

namespace TablePro.Core.Tests.Debugging;

/// <summary>A debugger whose start and preparation the test scripts.</summary>
internal sealed class FakeDebugger : IRoutineDebugger
{
    public FakeDebugger(Func<RoutineDebugRequest, CancellationToken, Task<IRoutineDebugSession>> start) => Start = start;

    public Func<RoutineDebugRequest, CancellationToken, Task<IRoutineDebugSession>> Start { get; set; }

    public Func<RoutineDebugPreparation, CancellationToken, Task> Prepare { get; set; } = (_, _) => Task.CompletedTask;

    public ConcurrentQueue<RoutineDebugRequest> Requests { get; } = new();

    public int Preparations;

    public RoutineDebugTarget? GetDebugTarget(DatabaseObject routine) => null;

    public Task<IReadOnlyList<RoutineDebugTarget>> GetDebugTargetsAsync(string? schema, CancellationToken cancellationToken) =>
        Task.FromResult<IReadOnlyList<RoutineDebugTarget>>([]);

    public Task<RoutineDebugPlan> PrepareDebugAsync(RoutineDebugTarget target, CancellationToken cancellationToken) => throw new NotSupportedException();

    public Task RunPreparationAsync(RoutineDebugPreparation preparation, CancellationToken cancellationToken)
    {
        Interlocked.Increment(ref Preparations);
        return Prepare(preparation, cancellationToken);
    }

    public Task<IRoutineDebugSession> StartDebugAsync(RoutineDebugRequest request, CancellationToken cancellationToken)
    {
        Requests.Enqueue(request);
        return Start(request, cancellationToken);
    }
}

/// <summary>A debug session that answers each call through what the test sets, and records every call it is asked.</summary>
internal sealed class FakeSession : IRoutineDebugSession
{
    public static readonly DebugUnit Unit = new("16384", "add_tax(numeric)");

    public FakeSession()
    {
        First = _ => Task.FromResult<DebugStop>(new DebugStop.Paused(new DebugLocation(Unit, 3)));
        Perform = _ => Task.FromResult<DebugStop>(new DebugStop.Paused(new DebugLocation(Unit, 4)));
    }

    public IReadOnlySet<DebugCommand> SupportedCommands { get; set; } = new HashSet<DebugCommand> { DebugCommand.Continue, DebugCommand.StepOver, DebugCommand.StepInto };

    public Channel<string> OutputChannel { get; } = Channel.CreateUnbounded<string>();

    public ChannelReader<string> Output => OutputChannel.Reader;

    public Func<CancellationToken, Task<DebugStop>> First { get; set; }

    public Func<DebugCommand, Task<DebugStop>> Perform { get; set; }

    public Func<DebugBreakpoint, Task<DebugBreakpoint?>> Set { get; set; } = b => Task.FromResult<DebugBreakpoint?>(b);

    public Func<DebugBreakpoint, Task> Remove { get; set; } = _ => Task.CompletedTask;

    public Func<int, Task<IReadOnlyList<DebugVariable>>> Variables { get; set; } =
        level => Task.FromResult<IReadOnlyList<DebugVariable>>([new DebugVariable(level == 0 ? "p_amount" : "p_n", DebugVariableKind.Argument, "numeric", "10", false)]);

    public Func<Task<IReadOnlyList<DebugFrame>>> Stack { get; set; } =
        () => Task.FromResult<IReadOnlyList<DebugFrame>>([new DebugFrame(0, new DebugLocation(Unit, 3), null), new DebugFrame(1, new DebugLocation(Unit, 9), null)]);

    public Func<Task<DebugStopOutcome>> Stop { get; set; } = () => Task.FromResult(DebugStopOutcome.Ended);

    public ConcurrentQueue<string> Calls { get; } = new();

    public int StopCalls;

    public int DisposeCalls;

    public Task<DebugStop> FirstStopAsync(CancellationToken cancellationToken)
    {
        Calls.Enqueue("first");
        return First(cancellationToken);
    }

    public Task<DebugStop> PerformAsync(DebugCommand command, CancellationToken cancellationToken)
    {
        Calls.Enqueue("perform " + command);
        return Perform(command);
    }

    public Task<string> GetSourceAsync(DebugUnit unit, CancellationToken cancellationToken)
    {
        Calls.Enqueue("source " + unit.Identity);
        return Task.FromResult("\nBEGIN\n  x := 1;\n  y := 2;\nEND;\n");
    }

    public Task<IReadOnlyList<DebugFrame>> GetStackAsync(CancellationToken cancellationToken)
    {
        Calls.Enqueue("stack");
        return Stack();
    }

    public Task<IReadOnlyList<DebugVariable>> GetVariablesAsync(int frameLevel, CancellationToken cancellationToken)
    {
        Calls.Enqueue("variables " + frameLevel);
        return Variables(frameLevel);
    }

    public Task<DebugBreakpoint?> SetBreakpointAsync(DebugBreakpoint breakpoint, CancellationToken cancellationToken)
    {
        Calls.Enqueue("set " + breakpoint.Line);
        return Set(breakpoint);
    }

    public Task RemoveBreakpointAsync(DebugBreakpoint breakpoint, CancellationToken cancellationToken)
    {
        Calls.Enqueue("remove " + breakpoint.Line);
        return Remove(breakpoint);
    }

    public Task<DebugStopOutcome> StopAsync()
    {
        Interlocked.Increment(ref StopCalls);
        Calls.Enqueue("stop");
        return Stop();
    }

    public ValueTask DisposeAsync()
    {
        Interlocked.Increment(ref DisposeCalls);
        OutputChannel.Writer.TryComplete();
        return ValueTask.CompletedTask;
    }
}

internal static class Eventually
{
    public static async Task TrueAsync(Func<bool> condition, string what, int milliseconds = 5_000)
    {
        var deadline = DateTime.UtcNow.AddMilliseconds(milliseconds);
        while (!condition())
        {
            if (DateTime.UtcNow > deadline)
            {
                Assert.Fail("Timed out waiting until " + what);
            }

            await Task.Delay(5, TestContext.Current.CancellationToken);
        }
    }
}
