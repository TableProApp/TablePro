using System.Diagnostics;
using System.Threading.Channels;
using TablePro.Core.Debugging;
using TablePro.Core.Drivers;
using TablePro.Core.Results;

namespace TablePro.Drivers.Oracle;

/// <summary>What the routine's call came to: the payload pieces it returned, or the error it ended with.</summary>
internal sealed record OracleDebugCallResult(IReadOnlyList<string?>? Pieces, Exception? Error)
{
    /// <summary>
    /// Only an answer from the server proves the target session ended: the call returned, or failed with an error the
    /// server sent. A call that failed because its transport did may have left that session running and holding locks.
    /// </summary>
    public bool EndedOnServer => Error is null || Error is OracleDebugServerException { AnsweredByServer: true };
}

/// <summary>
/// One Oracle debug run through DBMS_DEBUG: the target runs the routine in debug mode and the supervisor drives it. Both
/// are client connections, so it works through every transport the app has, where DBMS_DEBUG_JDWP would need the server
/// to reach this machine. Oracle documents DBMS_DEBUG as deprecated since 12.2, and it still works on 23ai.
/// </summary>
internal sealed class OracleDbmsDebugSession : IRoutineDebugSession
{
    // Step Out works: break_any_return stops in the caller after the return.
    private static readonly IReadOnlySet<DebugCommand> Commands = new HashSet<DebugCommand> { DebugCommand.Continue, DebugCommand.StepOver, DebugCommand.StepInto, DebugCommand.StepOut };

    private readonly IOracleDebugChannel _target;
    private readonly IOracleDebugChannel _supervisor;
    private readonly OracleDebugEntryPoint _entryPoint;
    private readonly OracleDebugInvocation _invocation;
    private readonly TimeSpan _callEndWait;
    private readonly TimeSpan _stopBudget;
    private readonly TimeSpan _cleanup;
    private readonly Channel<string> _output = Channel.CreateUnbounded<string>(new UnboundedChannelOptions { SingleReader = true });
    private readonly Dictionary<(OracleDebugUnit Unit, int Line), int> _placed = [];
    private readonly HashSet<(OracleDebugUnit Unit, int Line)> _pending = [];
    private readonly OracleDebugBreakpointHolds _holds = new();
    private readonly Dictionary<OracleDebugUnit, IReadOnlyList<int>> _lineMaps = [];
    private readonly Dictionary<OracleDebugUnit, PlSqlDeclarationScan> _scans = [];
    private readonly TaskCompletionSource _stopped = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly CancellationTokenSource _pinging = new();

    private volatile RunState _state = RunState.Ready;
    private volatile TargetPosition _targetPosition = TargetPosition.Running;
    private volatile bool _isDriving;
    private volatile bool _gaveUp;
    private volatile OracleDebugCallResult? _callResult;
    private int _stopRequested;
    private Task<OracleDebugCallResult>? _call;
    private Task? _pinger;
    private OracleDbmsDebugEvent? _lastEvent;
    private OracleDebugSessionIdentity? _targetIdentity;
    private DebugStopOutcome _stopResult = DebugStopOutcome.Ended;
    private int _disposed;

    internal OracleDbmsDebugSession(
        IOracleDebugChannel target,
        IOracleDebugChannel supervisor,
        OracleDebugEntryPoint entryPoint,
        OracleDebugInvocation invocation,
        TimeSpan? callEndWait = null,
        TimeSpan? stopBudget = null)
    {
        _target = target;
        _supervisor = supervisor;
        _entryPoint = entryPoint;
        _invocation = invocation;
        _callEndWait = callEndWait ?? TimeSpan.FromSeconds(30);
        _stopBudget = stopBudget ?? RoutineDebugging.StopBudget;

        // Kept back from the budget for the rollback and detach that follow the target's end.
        _cleanup = _stopBudget / 6;
        _output.Writer.TryWrite(OracleDebugText.UsingDbmsDebug);
    }

    private enum RunState
    {
        Ready,
        Running,
        Paused,
        Ended,
    }

    // What the supervisor last heard from the target. A wait whose answer never came leaves it unknown: the target may
    // then be paused, waiting for the supervisor, while no step shows it.
    private enum TargetPosition
    {
        Running,
        Paused,
        Unknown,
    }

    public IReadOnlySet<DebugCommand> SupportedCommands => Commands;

    public ChannelReader<string> Output => _output.Reader;

    private bool StopRequested => Volatile.Read(ref _stopRequested) == 1;

    private bool CallEnded => _callResult is not null;

    private bool CallEndedOnServer => _callResult?.EndedOnServer ?? false;

    /// <summary>
    /// Checks the call can be made, arms both sessions and starts nothing yet: the routine runs on the first stop. The
    /// session owns both channels from here, and a launch that fails or is cancelled closes them.
    /// </summary>
    public static async Task<OracleDbmsDebugSession> LaunchAsync(
        IOracleDebugChannel target,
        IOracleDebugChannel supervisor,
        OracleDebugEntryPoint entryPoint,
        IReadOnlyList<OracleDebugEntryPoint> overloads,
        RoutineDebugRequest request,
        CancellationToken cancellationToken,
        TimeSpan? stopBudget = null)
    {
        OracleDbmsDebugSession? session = null;
        try
        {
            var arguments = request.Arguments.ToDictionary(
                a => a.ParameterName,
                a => a.Value switch
                {
                    DebugArgumentValue.TextValue text => OracleDebugArgument.Of(text.Text),
                    DebugArgumentValue.DefaultValue => OracleDebugArgument.Default,
                    _ => OracleDebugArgument.Null,
                },
                StringComparer.Ordinal);
            if (OracleDebugStatements.Ambiguity(entryPoint, arguments, overloads) is { } ambiguity)
            {
                throw OracleDebugText.Ambiguous(ambiguity, entryPoint.Entry.Subprogram);
            }

            OracleDebugInvocation invocation;
            try
            {
                invocation = OracleDebugStatements.Invocation(entryPoint, arguments);
            }
            catch (OracleDebugArgumentException ex)
            {
                throw OracleDebugText.Argument(ex);
            }

            session = new OracleDbmsDebugSession(target, supervisor, entryPoint, invocation, stopBudget: stopBudget);
            var breakpoints = request.Breakpoints
                .Select(b => (Unit: OracleDebugUnit.FromIdentity(b.UnitIdentity), b.Line))
                .Where(b => b.Unit is not null)
                .Select(b => (b.Unit!, b.Line))
                .ToArray();
            await session.StartAsync(breakpoints, cancellationToken);
            cancellationToken.ThrowIfCancellationRequested();
            return session;
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            if (session is not null)
            {
                await session.StopAsync();
                await session.DisposeAsync();
            }
            else
            {
                await target.DisposeAsync();
                await supervisor.DisposeAsync();
            }

            cancellationToken.ThrowIfCancellationRequested();
            throw OracleDebugText.StartFailure(ex);
        }
    }

    // DEBUG_ON takes effect after its own call, so the next PL/SQL the target runs is the routine.
    internal async Task StartAsync(IReadOnlyList<(OracleDebugUnit Unit, int Line)> breakpoints, CancellationToken cancellationToken)
    {
        var debugId = "TP" + Guid.NewGuid().ToString("N");
        _targetIdentity = await SessionIdentityAsync(_target);
        await _target.ExecuteAsync(OracleDbmsDebugStatements.TargetSetup, [debugId], cancellationToken: cancellationToken);
        await _supervisor.ExecuteAsync(OracleDbmsDebugStatements.OwnSchema, cancellationToken: cancellationToken);
        await _supervisor.ExecuteAsync(OracleDbmsDebugStatements.Attach, [debugId], cancellationToken: cancellationToken);
        foreach (var (unit, line) in breakpoints)
        {
            await SetBreakpointCoreAsync(unit, line, atStart: true);
        }
    }

    public async Task<DebugStop> FirstStopAsync(CancellationToken cancellationToken)
    {
        if (_state != RunState.Ready)
        {
            throw OracleDebugText.Step(new OracleDebugEndedException());
        }

        if (StopRequested)
        {
            return new DebugStop.Failed(OracleDebugText.Stopped, null);
        }

        _state = RunState.Running;
        _call = RunCallAsync();
        _isDriving = true;
        try
        {
            return await StoppedOnErrorAsync(DriveToEntryAsync);
        }
        finally
        {
            _isDriving = false;
        }
    }

    public async Task<DebugStop> PerformAsync(DebugCommand command, CancellationToken cancellationToken)
    {
        if (StopRequested)
        {
            return new DebugStop.Failed(OracleDebugText.Stopped, null);
        }

        if (_state != RunState.Paused)
        {
            throw OracleDebugText.Step(new OracleDebugEndedException());
        }

        _state = RunState.Running;
        _isDriving = true;
        try
        {
            var flags = command switch
            {
                DebugCommand.StepOver => OracleDbmsDebugStatements.NextLine,
                DebugCommand.StepInto => OracleDbmsDebugStatements.AnyCall,
                DebugCommand.StepOut => OracleDbmsDebugStatements.AnyReturn,
                _ => OracleDbmsDebugStatements.BreakpointsOnly,
            };
            return await StoppedOnErrorAsync(async () => await SettleAsync(await WaitAsync(flags)));
        }
        finally
        {
            _isDriving = false;
        }
    }

    public async Task<string> GetSourceAsync(DebugUnit unit, CancellationToken cancellationToken)
    {
        var oracleUnit = OracleDebugUnit.FromIdentity(unit.Identity) ?? throw new RoutineDebugException(OracleDebugText.UnitUnreadable(unit.DisplayName), (string?)null);
        return await ReadableAsync(() => SourceAsync(oracleUnit));
    }

    public Task<IReadOnlyList<DebugFrame>> GetStackAsync(CancellationToken cancellationToken)
    {
        if (StopRequested || _state != RunState.Paused)
        {
            throw OracleDebugText.Step(new OracleDebugEndedException());
        }

        IReadOnlyList<DebugFrame> frames = [.. VisibleFrames().Select((frame, level) => new DebugFrame(level, Location(frame.Unit, frame.Line), frame.Subprogram))];
        return Task.FromResult(frames);
    }

    public async Task<IReadOnlyList<DebugVariable>> GetVariablesAsync(int frameLevel, CancellationToken cancellationToken)
    {
        if (_state != RunState.Paused)
        {
            throw OracleDebugText.Step(new OracleDebugEndedException());
        }

        return await ReadableAsync(() => ReadVariablesAsync(frameLevel));
    }

    public async Task<DebugBreakpoint?> SetBreakpointAsync(DebugBreakpoint breakpoint, CancellationToken cancellationToken)
    {
        if (OracleDebugUnit.FromIdentity(breakpoint.UnitIdentity) is not { } unit)
        {
            return null;
        }

        return await SetBreakpointCoreAsync(unit, breakpoint.Line, atStart: false) is { } landed ? breakpoint with { Line = landed } : null;
    }

    public async Task RemoveBreakpointAsync(DebugBreakpoint breakpoint, CancellationToken cancellationToken)
    {
        if (OracleDebugUnit.FromIdentity(breakpoint.UnitIdentity) is not { } unit || _holds.Release(breakpoint.Line, unit) is not { } landed)
        {
            return;
        }

        var key = (unit, landed);
        _pending.Remove(key);
        if (!_placed.Remove(key, out var number) || _state != RunState.Paused)
        {
            return;
        }

        try
        {
            await ReadableAsync(() => _supervisor.ExecuteAsync(OracleDbmsDebugStatements.DeleteBreakpoints([number])));
        }
        catch
        {
            // Still set on the server, so removing it again has to find it.
            _holds.Hold(landed, unit, breakpoint.Line);
            _placed[key] = number;
            throw;
        }
    }

    /// <summary>
    /// At a pause, abort_execution ends the routine with ORA-06543 and its work rolls back. While it runs, the target reads
    /// nothing the supervisor sends, abort included, so a running target is killed with ALTER SYSTEM KILL SESSION where
    /// the account may, and otherwise waited on for what is left of the budget.
    /// </summary>
    public async Task<DebugStopOutcome> StopAsync()
    {
        if (Interlocked.Exchange(ref _stopRequested, 1) == 1)
        {
            await _stopped.Task;
            return _stopResult;
        }

        await _pinging.CancelAsync();
        var deadline = Deadline(_stopBudget);
        var endBy = deadline - Ticks(_cleanup);
        if (_call is { } call)
        {
            bool ended;
            if (_targetPosition != TargetPosition.Running && !_isDriving)
            {
                // A read the stop overlaps holds the supervisor first; the abort waits for it at most half the budget.
                await BoundedAsync(Deadline(_stopBudget / 2), _supervisor, async () => await ResumeAsync(OracleDbmsDebugStatements.AbortExecution));
                ended = await CallEndsAsync(call, Deadline(TimeSpan.FromSeconds(1)));
                if (!ended)
                {
                    ended = await EndRunningTargetAsync(call, endBy);
                }
            }
            else
            {
                ended = await EndRunningTargetAsync(call, endBy);
            }

            ended = ended || CallEndedOnServer;
            if (ended)
            {
                await BoundedAsync(deadline, _target, () => _target.ExecuteAsync("ROLLBACK"));
            }
            else
            {
                _gaveUp = true;
            }

            _stopResult = ended ? DebugStopOutcome.Ended : DebugStopOutcome.Unconfirmed(OracleDebugText.StillRunning, OracleDebugText.StillRunningDetail(_targetIdentity));
        }

        // Before the routine ran, the target only switched debug mode on; it holds no work.
        if (!_isDriving)
        {
            await BoundedAsync(deadline, _supervisor, () => _supervisor.ExecuteAsync(OracleDbmsDebugStatements.Detach));
        }

        _state = RunState.Ended;
        _output.Writer.TryComplete();
        _stopped.TrySetResult();
        return _stopResult;
    }

    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref _disposed, 1) == 1)
        {
            return;
        }

        await _pinging.CancelAsync();
        _output.Writer.TryComplete();
        await _target.DisposeAsync();
        await _supervisor.DisposeAsync();
        _pinging.Dispose();
    }

    private async Task<OracleDebugCallResult> RunCallAsync()
    {
        OracleDebugCallResult result;
        try
        {
            result = new OracleDebugCallResult(await _target.ExecuteAsync(_invocation.Block, _invocation.Binds, readsRows: true), null);
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            result = new OracleDebugCallResult(null, ex);
        }

        _callResult = result;
        return result;
    }

    private async Task<DebugStop> DriveToEntryAsync()
    {
        var current = await WaitAsync(null);
        if (!current.IsPause)
        {
            return await ConcludeAsync();
        }

        var (entryBreakpoints, entryLines) = await PlaceEntryBreakpointsAsync();
        foreach (var key in _pending.ToArray())
        {
            _pending.Remove(key);
            if (await PlaceNowAsync(key.Unit, key.Line) is { } number)
            {
                _placed[key] = number;
            }
            else
            {
                _holds.Drop(key.Line, key.Unit);
                _output.Writer.TryWrite(OracleDebugText.BreakpointHasNoCode(key.Unit, key.Line));
            }
        }

        if (entryBreakpoints.Count == 0)
        {
            current = await StepToEntryAsync(current);
        }
        else
        {
            // A breakpoint of the user's on the same header line can be the number that answers.
            bool IsEntry(OracleDbmsDebugEvent e) =>
                entryBreakpoints.Contains(e.Breakpoint ?? -1)
                || (LocationOf(e) is { } location && location.Unit == _entryPoint.Entry.Unit && entryLines.Contains(location.Line));

            do
            {
                current = await WaitAsync(OracleDbmsDebugStatements.BreakpointsOnly);
            }
            while (current.IsPause && !IsEntry(current) && !StopRequested);

            var temporary = entryBreakpoints.Except(_placed.Values).Order().ToArray();
            if (current.IsPause && temporary.Length > 0)
            {
                await _supervisor.ExecuteAsync(OracleDbmsDebugStatements.DeleteBreakpoints(temporary));
            }
        }

        return await SettleAsync(current);
    }

    /// <summary>
    /// The header line of every overload with the entry point's name. DBMS_DEBUG accepts a breakpoint there and stops
    /// before the declarations run.
    /// </summary>
    private async Task<(HashSet<int> Numbers, HashSet<int> Lines)> PlaceEntryBreakpointsAsync()
    {
        var unit = _entryPoint.Entry.Unit;
        IReadOnlyList<int> headers = _entryPoint.Entry.IsPackaged ? (await ScanAsync(unit)).HeaderLines(_entryPoint.Entry.Subprogram) : [1];
        var executable = await ExecutableLinesAsync(unit);
        var numbers = new HashSet<int>();
        var lines = new HashSet<int>();
        foreach (var header in headers)
        {
            var line = executable.FirstOrDefault(l => l >= header);
            if (line == 0)
            {
                continue;
            }

            lines.Add(line);
            if (await PlaceNowAsync(unit, line) is { } number)
            {
                numbers.Add(number);
            }
        }

        return (numbers, lines);
    }

    // Without a header line to stop at, step into calls until the entry point's own frame runs.
    private async Task<OracleDbmsDebugEvent> StepToEntryAsync(OracleDbmsDebugEvent start)
    {
        var current = start;
        for (var i = 0; i < 10_000 && current.IsPause && !StopRequested; i++)
        {
            current = await WaitAsync(OracleDbmsDebugStatements.AnyCall);
            if (current.Backtrace.Count > 0 && current.Backtrace[^1] is var top && top.Unit == _entryPoint.Entry.Unit
                && (!_entryPoint.Entry.IsPackaged || string.Equals(top.EntryPoint, _entryPoint.Entry.Subprogram, StringComparison.OrdinalIgnoreCase)))
            {
                break;
            }
        }

        return current;
    }

    // A call a stop overlapped ends as stopped, whatever its own statements reported after the connections closed.
    private async Task<DebugStop> StoppedOnErrorAsync(Func<Task<DebugStop>> body)
    {
        try
        {
            return await body();
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            if (StopRequested)
            {
                return await OutcomeOfStopAsync();
            }

            throw OracleDebugText.Step(ex);
        }
    }

    // A stop in the anonymous block that called the entry point has nothing to show, so it runs on.
    private async Task<DebugStop> SettleAsync(OracleDbmsDebugEvent start)
    {
        var current = start;
        while (current.IsPause && !StopRequested && LocationOf(current) is null)
        {
            try
            {
                current = await WaitAsync(OracleDbmsDebugStatements.BreakpointsOnly);
            }
            catch (Exception ex) when (ex is not OutOfMemoryException)
            {
                break;
            }
        }

        if (StopRequested && current.IsPause)
        {
            try
            {
                await ResumeAsync(OracleDbmsDebugStatements.AbortExecution);
            }
            catch (Exception ex) when (ex is not OutOfMemoryException)
            {
                // The stop goes on to kill the session or give it up; this abort was only the polite way.
            }
        }

        if (!current.IsPause || StopRequested || LocationOf(current) is not { } location)
        {
            return await ConcludeAsync();
        }

        _lastEvent = current;
        _state = RunState.Paused;
        return new DebugStop.Paused(Location(location.Unit, location.Line));
    }

    /// <summary>
    /// One supervisor wait lasts <see cref="OracleDbmsDebugStatements.SupervisorTimeoutSeconds"/>; between waits it checks
    /// for a stop and for the routine having ended, which a wait after the target finished would otherwise sit out.
    /// </summary>
    private async Task<OracleDbmsDebugEvent> WaitAsync(int? flags)
    {
        var current = await ResumeAsync(flags);
        while (current.TimedOut)
        {
            if (_gaveUp || CallEnded || _stopped.Task.IsCompleted)
            {
                return current;
            }

            current = await ResumeAsync(null);
        }

        if (StopRequested && !_stopped.Task.IsCompleted && current.IsPause)
        {
            current = await ResumeAsync(OracleDbmsDebugStatements.AbortExecution);
        }

        return current;
    }

    private async Task<OracleDbmsDebugEvent> ResumeAsync(int? flags)
    {
        _targetPosition = TargetPosition.Unknown;
        var fields = await PayloadAsync(OracleDbmsDebugStatements.Resume(flags), null, _supervisor);
        var current = OracleDbmsDebugStatements.Event(fields);
        _targetPosition = current.IsPause ? TargetPosition.Paused : TargetPosition.Running;

        // Here, not where a step reports its pause: a step that fails after the target paused leaves the state running.
        if (current.IsPause && !StopRequested)
        {
            _pinger ??= PingAsync(_pinging.Token);
        }

        return current;
    }

    private static DebugUnitLocation? LocationOf(OracleDbmsDebugEvent e)
    {
        if (e.Backtrace.Count == 0 || e.Backtrace[^1] is not { Unit: { } unit } top || (e.Line ?? top.Line) is not > 0)
        {
            return null;
        }

        return new DebugUnitLocation(unit, e.Line ?? top.Line ?? 0);
    }

    private async Task<DebugStop> ConcludeAsync()
    {
        await _pinging.CancelAsync();
        if (StopRequested)
        {
            return await OutcomeOfStopAsync();
        }

        OracleDebugCallResult? result;
        if (_call is { } call)
        {
            result = await Task.WhenAny(call, Task.Delay(_callEndWait)) == call ? await call : null;
        }
        else
        {
            result = new OracleDebugCallResult(null, new OracleDebugEndedException());
        }

        var stop = await ConcludeCallAsync(result, StopRequested);
        if (_gaveUp)
        {
            stop = new DebugStop.Failed(OracleDebugText.StillRunning, OracleDebugText.StillRunningDetail(_targetIdentity));
        }

        try
        {
            await _supervisor.ExecuteAsync(OracleDbmsDebugStatements.Detach);
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            Trace.TraceWarning("Detaching the DBMS_DEBUG supervisor failed: {0}", ex.Message);
        }

        _state = RunState.Ended;
        _output.Writer.TryComplete();
        return stop;
    }

    /// <summary>
    /// The routine's own result: its outputs and a commit on success; a rollback otherwise, and always after a stop. A null
    /// result is a call still running, which holds the target: a ROLLBACK would queue behind it with no bound.
    /// </summary>
    private async Task<DebugStop> ConcludeCallAsync(OracleDebugCallResult? result, bool stopped)
    {
        if (result is null)
        {
            return new DebugStop.Failed(OracleDebugText.StillRunning, OracleDebugText.StillRunningDetail(_targetIdentity));
        }

        OracleDebugInvocationReport? report = null;
        if (result.Pieces is { } pieces)
        {
            try
            {
                report = OracleDebugStatements.InvocationReport(OracleDebugPayload.Parse(OracleDebugPayload.Join(pieces)));
            }
            catch (FormatException)
            {
                report = null;
            }
        }

        foreach (var line in report?.Lines ?? [])
        {
            _output.Writer.TryWrite(line);
        }

        if (!stopped && report is { Succeeded: true })
        {
            try
            {
                await _target.ExecuteAsync("COMMIT");
            }
            catch (Exception ex) when (ex is not OutOfMemoryException)
            {
                return new DebugStop.Failed(OracleDebugText.ConnectionLost, ex.Message);
            }

            return new DebugStop.Finished(Outcome(report));
        }

        try
        {
            await _target.ExecuteAsync("ROLLBACK");
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            Trace.TraceWarning("Rolling back the debug target failed: {0}", ex.Message);
        }

        if (stopped)
        {
            return new DebugStop.Failed(OracleDebugText.Stopped, null);
        }

        if (report is not null)
        {
            return new DebugStop.Failed(OracleDebugText.RoutineFailed, string.IsNullOrEmpty(report.Error) ? null : report.Error);
        }

        if (result.Error is { } error)
        {
            // Only the server's own error says the routine failed and rolled back; a dropped connection says neither.
            return result.EndedOnServer ? new DebugStop.Failed(OracleDebugText.RoutineFailed, error.Message) : new DebugStop.Failed(OracleDebugText.ConnectionLost, error.Message);
        }

        return new DebugStop.Failed(OracleDebugText.ConnectionLost, null);
    }

    private ResultSet? Outcome(OracleDebugInvocationReport report)
    {
        if (report.Outputs.Count == 0)
        {
            return null;
        }

        var types = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var parameter in _entryPoint.Parameters)
        {
            types[parameter.Name] = parameter.DisplayType;
        }

        if (_entryPoint.Result is { } result)
        {
            types[_entryPoint.Entry.Subprogram] = result.DisplayType;
        }

        var columns = report.Outputs.Select(o => new ResultColumn(o.Name, types.GetValueOrDefault(o.Name, string.Empty), typeof(string))).ToArray();
        return new ResultSet(columns, [report.Outputs.Select(o => (object?)o.Value).ToArray()]);
    }

    // The stop owns the cleanup and the connections are the caller's once it returns, so a waiting call only reports.
    private async Task<DebugStop> OutcomeOfStopAsync()
    {
        await _stopped.Task;
        return _gaveUp
            ? new DebugStop.Failed(OracleDebugText.StillRunning, OracleDebugText.StillRunningDetail(_targetIdentity))
            : new DebugStop.Failed(OracleDebugText.Stopped, null);
    }

    /// <summary>
    /// The target aborts itself after <see cref="OracleDbmsDebugStatements.TargetTimeoutSeconds"/> without a word from the
    /// supervisor, which is what ends it if the app goes away. PING keeps it waiting while the user reads a pause.
    /// </summary>
    private async Task PingAsync(CancellationToken cancellationToken)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(OracleDbmsDebugStatements.PingIntervalSeconds));
        try
        {
            while (await timer.WaitForNextTickAsync(cancellationToken))
            {
                if (_targetPosition != TargetPosition.Paused || _isDriving || StopRequested)
                {
                    continue;
                }

                try
                {
                    await _supervisor.ExecuteAsync(OracleDbmsDebugStatements.Ping, cancellationToken: cancellationToken);
                }
                catch (Exception ex) when (ex is not OperationCanceledException and not OutOfMemoryException)
                {
                    Trace.TraceWarning("DBMS_DEBUG ping failed: {0}", ex.Message);
                }
            }
        }
        catch (OperationCanceledException)
        {
        }
    }

    // A call a stop overlaps ends with the stop, not with what it read from a closing connection.
    private async Task<T> ReadableAsync<T>(Func<Task<T>> body)
    {
        if (StopRequested)
        {
            throw OracleDebugText.Step(new OracleDebugEndedException());
        }

        T value;
        try
        {
            value = await body();
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            throw OracleDebugText.Step(StopRequested ? new OracleDebugEndedException() : ex);
        }

        return StopRequested ? throw OracleDebugText.Step(new OracleDebugEndedException()) : value;
    }

    private async Task<int?> SetBreakpointCoreAsync(OracleDebugUnit unit, int line, bool atStart)
    {
        if (_state == RunState.Ended)
        {
            throw OracleDebugText.Step(new OracleDebugEndedException());
        }

        if (await ReadableAsync(() => PlaceBreakpointAsync(unit, line)) is not { } landed)
        {
            return null;
        }

        // One sent at start is held by the line it asked for, since its caller never learns where it landed.
        _holds.Hold(landed, unit, atStart ? line : landed);
        return landed;
    }

    private async Task<int?> PlaceBreakpointAsync(OracleDebugUnit unit, int line)
    {
        var resolved = (await ExecutableLinesAsync(unit)).FirstOrDefault(l => l >= line);
        if (resolved == 0)
        {
            return null;
        }

        var key = (unit, resolved);
        if (_placed.ContainsKey(key) || _pending.Contains(key))
        {
            return resolved;
        }

        // Before the target starts there is nothing for SET_BREAKPOINT to talk to.
        if (_state != RunState.Paused)
        {
            _pending.Add(key);
            return resolved;
        }

        if (await PlaceNowAsync(unit, resolved) is not { } number)
        {
            return null;
        }

        _placed[key] = number;
        return resolved;
    }

    private async Task<int?> PlaceNowAsync(OracleDebugUnit unit, int line)
    {
        var answer = OracleDbmsDebugStatements.BreakpointAnswer(await PayloadAsync(OracleDbmsDebugStatements.SetBreakpoint(unit, line), null, _supervisor));
        return answer.Status == OracleDbmsDebugStatements.StatusSuccess ? answer.Number : null;
    }

    private async Task<IReadOnlyList<int>> ExecutableLinesAsync(OracleDebugUnit unit)
    {
        if (!_lineMaps.TryGetValue(unit, out var lines))
        {
            lines = OracleDbmsDebugStatements.ExecutableLines(await PayloadAsync(OracleDbmsDebugStatements.LineMap(unit), null, _supervisor)) ?? [];
            _lineMaps[unit] = lines;
        }

        return lines;
    }

    private async Task<string> SourceAsync(OracleDebugUnit unit)
    {
        var rows = await _supervisor.QueryAsync(OracleDebugStatements.Source(unit));
        var lines = rows
            .Select(row => (Parsed: int.TryParse(row.Count > 0 ? row[0]?.Trim() : null, out var line), Line: line, Text: row.Count > 1 ? row[1] : null))
            .Where(r => r.Parsed)
            .Select(r => (r.Line, r.Text))
            .ToArray();
        return lines.Length > 0 ? OracleDebugStatements.AssembleSource(lines) : throw new RoutineDebugException("TablePro can't read this unit's source.", (string?)null);
    }

    private async Task<PlSqlDeclarationScan> ScanAsync(OracleDebugUnit unit)
    {
        if (!_scans.TryGetValue(unit, out var scan))
        {
            scan = new PlSqlDeclarationScan(await SourceAsync(unit));
            _scans[unit] = scan;
        }

        return scan;
    }

    private List<VisibleFrame> VisibleFrames()
    {
        var frames = new List<VisibleFrame>();
        if (_lastEvent is not { } last)
        {
            return frames;
        }

        var count = last.Backtrace.Count;
        for (var offset = count - 1; offset >= 0; offset--)
        {
            var frame = last.Backtrace[offset];
            if (frame.Unit is not { } unit)
            {
                continue;
            }

            var isTop = offset == count - 1;
            var line = isTop ? last.Line ?? frame.Line ?? 0 : frame.Line ?? 0;

            // GET_VALUE's frame number: 0 for the running frame, else the PRINT_BACKTRACE index.
            frames.Add(new VisibleFrame(unit, line, frame.EntryPoint, isTop ? 0 : offset + 1));
        }

        return frames;
    }

    private async Task<IReadOnlyList<DebugVariable>> ReadVariablesAsync(int level)
    {
        var frames = VisibleFrames();
        if (level < 0 || level >= frames.Count)
        {
            return [];
        }

        var frame = frames[level];
        IReadOnlyList<PlSqlDeclaration> candidates;
        try
        {
            candidates = (await ScanAsync(frame.Unit)).Candidates(frame.Line);
        }
        catch (RoutineDebugException)
        {
            candidates = [];
        }

        var requests = candidates.Select(c => new OracleDbmsValueRequest(c.LookupName, frame.ValueFrame, null)).ToList();
        var package = new List<PlSqlDeclaration>();
        if (frame.Unit.Kind is OracleDebugUnitKind.PackageBody or OracleDebugUnitKind.Package)
        {
            foreach (var kind in new[] { OracleDebugUnitKind.PackageBody, OracleDebugUnitKind.Package })
            {
                var owner = frame.Unit with { Kind = kind };
                IEnumerable<PlSqlDeclaration> declarations;
                try
                {
                    declarations = (await ScanAsync(owner)).PackageVariables;
                }
                catch (RoutineDebugException)
                {
                    declarations = [];
                }

                foreach (var declaration in declarations)
                {
                    package.Add(declaration);
                    requests.Add(new OracleDbmsValueRequest(declaration.LookupName, null, owner));
                }
            }
        }

        if (requests.Count == 0)
        {
            return [];
        }

        var (block, binds) = OracleDbmsDebugStatements.Values(requests);
        var answers = OracleDbmsDebugStatements.ValueAnswers(await PayloadAsync(block, binds, _supervisor), requests.Count);
        var variables = new List<DebugVariable>();
        for (var index = 0; index < answers.Count; index++)
        {
            var isPackage = index >= candidates.Count;
            var declaration = isPackage ? package[index - candidates.Count] : candidates[index];

            // GET_VALUE resolves a quoted name with a dot but not one with a space, so that one is shown unreadable.
            var value = OracleDbmsDebugStatements.Value(answers[index].Status, answers[index].Value)
                ?? (declaration.Name.Any(char.IsWhiteSpace) ? OracleDebugValue.Unavailable : null);
            if (value is null)
            {
                continue;
            }

            var kind = isPackage ? DebugVariableKind.Package : declaration.Kind == PlSqlDeclarationKind.Parameter ? DebugVariableKind.Argument : DebugVariableKind.Local;
            variables.Add(new DebugVariable(declaration.Name, kind, declaration.TypeText, value.Display, declaration.Kind == PlSqlDeclarationKind.Constant));
        }

        return variables;
    }

    private async Task<bool> EndRunningTargetAsync(Task<OracleDebugCallResult> call, long endBy)
    {
        // A target running between breakpoints reads nothing the supervisor sends, so the kill goes first; what is left
        // of the budget waits for the end, which a refused kill leaves to the routine itself.
        await KillTargetAsync(endBy);
        return Remaining(endBy) > TimeSpan.Zero && await CallEndsAsync(call, endBy);
    }

    /// <summary>
    /// The server ends a killed session at its next check, even inside a loop or a SQL statement, and rolls its work back.
    /// ORA-00031 "session marked for kill" is that taking effect on a busy session; ORA-01031 is an account without ALTER SYSTEM.
    /// </summary>
    private async Task KillTargetAsync(long deadline)
    {
        if (_targetIdentity is not { } identity || OracleDbmsDebugStatements.KillSession(identity) is not { } statement || Remaining(deadline) <= TimeSpan.Zero)
        {
            return;
        }

        await BoundedAsync(deadline, _supervisor, () => _supervisor.ExecuteAsync(statement));
    }

    // A call that failed on its own connection ended only on this side, so the stop goes on as for one still running.
    private async Task<bool> CallEndsAsync(Task<OracleDebugCallResult> call, long deadline)
    {
        var remaining = Remaining(deadline);
        if (!call.IsCompleted && (remaining <= TimeSpan.Zero || await Task.WhenAny(call, Task.Delay(remaining)) != call))
        {
            return CallEndedOnServer;
        }

        return (await call).EndedOnServer;
    }

    // A statement that would run past the deadline has its channel's statement broken, which is what ends it.
    private static async Task BoundedAsync<T>(long deadline, IOracleDebugChannel channel, Func<Task<T>> body)
    {
        var remaining = Remaining(deadline);
        if (remaining <= TimeSpan.Zero)
        {
            return;
        }

        var work = Swallow(body);
        if (await Task.WhenAny(work, Task.Delay(remaining)) != work)
        {
            channel.Cancel();
        }
    }

    private static async Task Swallow<T>(Func<Task<T>> body)
    {
        try
        {
            await body();
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            Trace.TraceInformation("A debugger cleanup statement failed: {0}", ex.Message);
        }
    }

    private static async Task<IReadOnlyList<string?>> PayloadAsync(string block, IReadOnlyList<string?>? binds, IOracleDebugChannel channel)
    {
        var pieces = await channel.ExecuteAsync(block, binds, readsRows: true);
        return OracleDebugPayload.Parse(OracleDebugPayload.Join(pieces));
    }

    /// <summary>The target's SID and SERIAL#, read before debug mode is on, so its own PL/SQL does not stop it.</summary>
    private static async Task<OracleDebugSessionIdentity?> SessionIdentityAsync(IOracleDebugChannel channel)
    {
        foreach (var query in OracleDbmsDebugStatements.SessionIdentityQueries)
        {
            try
            {
                var rows = await channel.QueryAsync(query);
                if (rows.Count > 0 && OracleDbmsDebugStatements.SessionIdentity(rows[0]) is { } identity)
                {
                    return identity;
                }
            }
            catch (OracleDebugServerException)
            {
                // Without the grant this query needs, the next one asks for less.
            }
        }

        return null;
    }

    private static DebugLocation Location(OracleDebugUnit unit, int line) => new(new DebugUnit(unit.Identity, unit.DisplayName), line);

    private static long Deadline(TimeSpan budget) => Stopwatch.GetTimestamp() + Ticks(budget);

    private static long Ticks(TimeSpan span) => (long)(span.TotalSeconds * Stopwatch.Frequency);

    private static TimeSpan Remaining(long deadline) => Stopwatch.GetElapsedTime(Stopwatch.GetTimestamp(), deadline);

    private sealed record DebugUnitLocation(OracleDebugUnit Unit, int Line);

    private sealed record VisibleFrame(OracleDebugUnit Unit, int Line, string? Subprogram, int ValueFrame);
}

/// <summary>
/// The lines a caller removes each breakpoint by, keyed by the line it landed on. One sent at start is held by the line it
/// asked for, since its caller never learns where it landed; one set later, by the line it was answered with.
/// </summary>
internal sealed class OracleDebugBreakpointHolds
{
    private readonly Dictionary<OracleDebugUnit, Dictionary<int, HashSet<int>>> _holders = [];

    public void Hold(int landed, OracleDebugUnit unit, int line)
    {
        if (!_holders.TryGetValue(unit, out var byLanded))
        {
            byLanded = [];
            _holders[unit] = byLanded;
        }

        if (!byLanded.TryGetValue(landed, out var lines))
        {
            lines = [];
            byLanded[landed] = lines;
        }

        lines.Add(line);
    }

    public void Drop(int landed, OracleDebugUnit unit)
    {
        if (_holders.TryGetValue(unit, out var byLanded))
        {
            byLanded.Remove(landed);
        }
    }

    /// <summary>The landed line of the breakpoint <paramref name="line"/> names, once no other line holds it; null while one still does.</summary>
    public int? Release(int line, OracleDebugUnit unit)
    {
        if (!_holders.TryGetValue(unit, out var byLanded) || byLanded.FirstOrDefault(p => p.Value.Contains(line)) is not { Value: not null } held)
        {
            Drop(line, unit);
            return line;
        }

        held.Value.Remove(line);
        if (held.Value.Count > 0)
        {
            return null;
        }

        byLanded.Remove(held.Key);
        return held.Key;
    }
}
