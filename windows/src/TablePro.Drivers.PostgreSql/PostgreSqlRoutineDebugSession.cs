using System.Diagnostics;
using System.Globalization;
using System.Threading.Channels;
using TablePro.Core.Drivers;

namespace TablePro.Drivers.PostgreSql;

/// <summary>
/// One PL/pgSQL debug run. The target connection runs the routine and blocks for the whole run; the proxy connection
/// drives it through pldbgapi. Nothing reaches the proxy while a step waits, since client traffic then ends the
/// debugger, so a stop ends the target through the abort that queues behind the step, or through the target's own cancel.
/// </summary>
internal sealed class PostgreSqlRoutineDebugSession : IRoutineDebugSession
{
    private static readonly TimeSpan AttachRetryDelay = TimeSpan.FromMilliseconds(300);
    private static readonly TimeSpan CancelRetryDelay = TimeSpan.FromMilliseconds(250);

    private readonly IPostgreSqlDebugConnection _target;
    private readonly IPostgreSqlDebugConnection _proxy;
    private readonly Func<CancellationToken, Task<IPostgreSqlDebugConnection>> _openConnection;
    private readonly List<IPostgreSqlDebugConnection> _rescues = [];
    private readonly PostgreSqlDebugRoutine _routine;
    private readonly string _extensionSchema;
    private readonly int? _targetProcess;
    private readonly IReadOnlyList<DebugBreakpoint> _initialBreakpoints;
    private readonly Channel<string> _output = Channel.CreateUnbounded<string>(new UnboundedChannelOptions { SingleReader = true });
    private readonly PostgreSqlDebugRendezvous _rendezvous = new();

    // Settled the moment a stop is asked, so a read it overlaps returns at once, and on every other way the run ends.
    private readonly PostgreSqlDebugRendezvous _stopSignal = new();
    private readonly TimeSpan _stopBudget;
    private readonly Lock _stopLock = new();

    private volatile Phase _phase = Phase.Starting;
    private volatile bool _stopRequested;
    private volatile bool _abortDelivered;
    private volatile bool _backendGone;
    private volatile bool _proxyInterrupted;
    private volatile bool _endedByInterruption;
    private bool _hasReportedFirstStop;
    private DebugLocation? _lastStop;
    private int _selectedFrame;
    private int? _port;
    private int? _handle;
    private Task<PostgreSqlDebugCallOutcome>? _targetCall;
    private DebugStop? _terminalStop;
    private Task? _stopTask;
    private long? _stopDeadline;
    private int _abortSent;
    private int _disposed;

    internal PostgreSqlRoutineDebugSession(
        IPostgreSqlDebugConnection target,
        IPostgreSqlDebugConnection proxy,
        Func<CancellationToken, Task<IPostgreSqlDebugConnection>> openConnection,
        PostgreSqlDebugRoutine routine,
        string extensionSchema,
        IReadOnlyList<DebugBreakpoint> breakpoints,
        TimeSpan? stopBudget = null)
    {
        _target = target;
        _proxy = proxy;
        _openConnection = openConnection;
        _routine = routine;
        _extensionSchema = extensionSchema;
        _targetProcess = target.ProcessId;
        _initialBreakpoints = breakpoints;

        // The caller closes every connection soon after the stop returns, so ending the target, a rescue session
        // included, fits inside its budget.
        _stopBudget = stopBudget ?? TimeSpan.FromMilliseconds(2_500);
    }

    private enum Phase
    {
        Starting,
        Paused,
        Running,
        Broken,
        Ended,
    }

    public IReadOnlySet<DebugCommand> SupportedCommands => PostgreSqlDebugProtocol.SupportedCommands;

    public ChannelReader<string> Output => _output.Reader;

    /// <summary>
    /// Prepares both connections, arms the debugger on the target and starts the routine. The session owns both
    /// connections from here: a start that fails closes them.
    /// </summary>
    public static async Task<PostgreSqlRoutineDebugSession> StartAsync(
        IPostgreSqlDebugConnection target,
        IPostgreSqlDebugConnection proxy,
        Func<CancellationToken, Task<IPostgreSqlDebugConnection>> openConnection,
        RoutineDebugRequest request,
        CancellationToken cancellationToken,
        TimeSpan? stopBudget = null)
    {
        PostgreSqlRoutineDebugSession? session = null;
        try
        {
            foreach (var statement in PostgreSqlDebugProtocol.SessionSettings(proxy.ServerVersion, isTarget: false))
            {
                await proxy.QueryAsync(statement, null, cancellationToken);
            }

            var oid = PostgreSqlDebugProtocol.Oid(request.EntryPoint.Identity) ?? throw PostgreSqlDebugErrors.RoutineNotFound(request.EntryPoint.DisplayName);
            var routine = await ReadRoutineAsync(proxy, oid, request.EntryPoint.DisplayName, cancellationToken);
            var extensionSchema = routine.DebuggerSchema();
            foreach (var statement in PostgreSqlDebugProtocol.SessionSettings(target.ServerVersion, isTarget: true))
            {
                await target.QueryAsync(statement, null, cancellationToken);
            }

            var call = PostgreSqlDebugProtocol.Call(routine, request.Arguments);
            try
            {
                await target.QueryAsync(PostgreSqlDebugProtocol.OidDebugStatement(extensionSchema, oid), null, cancellationToken);
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                throw PostgreSqlDebugProtocol.StartFailure(ex, routine.Database, routine.DisplayName);
            }

            // Nothing runs on the target yet, so a start cancelled here leaves nothing behind.
            cancellationToken.ThrowIfCancellationRequested();
            session = new PostgreSqlRoutineDebugSession(target, proxy, openConnection, routine, extensionSchema, request.Breakpoints, stopBudget);
            await session.StartCoreAsync(call, cancellationToken);
            return session;
        }
        catch
        {
            if (session is not null)
            {
                await session.DisposeAsync();
            }
            else
            {
                await target.DisposeAsync();
                await proxy.DisposeAsync();
            }

            throw;
        }
    }

    internal static async Task<PostgreSqlDebugRoutine> ReadRoutineAsync(IPostgreSqlDebugConnection connection, uint oid, string name, CancellationToken cancellationToken)
    {
        var rows = await connection.QueryAsync(PostgreSqlDebugProtocol.RoutineQuery(oid, connection.ServerVersion), null, cancellationToken);
        var routine = rows.Count > 0 ? new PostgreSqlDebugRoutine(rows[0], oid.ToString(CultureInfo.InvariantCulture)) : null;
        return routine is { Exists: true } ? routine : throw PostgreSqlDebugErrors.RoutineNotFound(name);
    }

    /// <summary>
    /// Sends the call on the target, waits for the PLDBGBREAK notice it raises on entering the routine, and attaches the
    /// proxy to the backend number that notice names.
    /// </summary>
    internal async Task StartCoreAsync(PostgreSqlDebugCall call, CancellationToken cancellationToken)
    {
        _target.Notice += OnTargetNotice;
        _targetCall = RunTargetCallAsync(call);

        int? delivered;
        await using (cancellationToken.Register(() => CancelUntilEntered(Deadline(_stopBudget))))
        {
            delivered = await _rendezvous.PortAsync();
        }

        switch (PostgreSqlDebugProtocol.StartStep(delivered, cancellationToken.IsCancellationRequested || _stopRequested))
        {
            case PostgreSqlDebugStartStep.EndedBeforeEntry:
                await EndBeforeEntryAsync();
                break;
            case PostgreSqlDebugStartStep.Cancelled:
                _phase = Phase.Ended;
                _stopSignal.Settle();
                if (_rendezvous.IsAbandoned)
                {
                    throw PostgreSqlDebugErrors.TargetAbandoned(_targetProcess, null);
                }

                await _targetCall;
                throw new OperationCanceledException(cancellationToken);
            case PostgreSqlDebugStartStep.AttachAndAbort:
                _port = delivered;
                throw await StopForStartAsync(new OperationCanceledException(cancellationToken));
            default:
                _port = delivered;
                Exception? failure = null;
                try
                {
                    _handle = await AttachAsync(_proxy, delivered!.Value);
                    _phase = Phase.Paused;
                }
                catch (Exception ex) when (ex is not OutOfMemoryException)
                {
                    _phase = Phase.Broken;
                    failure = PostgreSqlDebugProtocol.StartFailure(ex, _routine.Database, _routine.DisplayName);
                }

                if (failure is not null)
                {
                    throw await StopForStartAsync(failure);
                }

                // The attach does not observe cancellation, so a start cancelled meanwhile is ended here, as Stop would.
                if (cancellationToken.IsCancellationRequested)
                {
                    throw await StopForStartAsync(new OperationCanceledException(cancellationToken));
                }

                break;
        }
    }

    public async Task<DebugStop> FirstStopAsync(CancellationToken cancellationToken)
    {
        if (_terminalStop is { } terminal)
        {
            return terminal;
        }

        if (_stopRequested)
        {
            return await OutcomeAfterStopAsync();
        }

        if (_hasReportedFirstStop && _phase == Phase.Paused && _lastStop is { } last)
        {
            return new DebugStop.Paused(last);
        }

        if (_phase != Phase.Paused || _handle is not { } handle)
        {
            throw PostgreSqlDebugErrors.NotPaused();
        }

        return await AdvanceAsync(PostgreSqlDebugProtocol.WaitStatement(_extensionSchema, handle), _initialBreakpoints);
    }

    public async Task<DebugStop> PerformAsync(DebugCommand command, CancellationToken cancellationToken)
    {
        if (_terminalStop is { } terminal)
        {
            return terminal;
        }

        if (_stopRequested)
        {
            return await OutcomeAfterStopAsync();
        }

        if (_phase != Phase.Paused || !_hasReportedFirstStop || _handle is not { } handle)
        {
            throw PostgreSqlDebugErrors.NotPaused();
        }

        var statement = PostgreSqlDebugProtocol.StepStatement(command, _extensionSchema, handle) ?? throw PostgreSqlDebugErrors.UnsupportedCommand();
        return await AdvanceAsync(statement, []);
    }

    public async Task<string> GetSourceAsync(DebugUnit unit, CancellationToken cancellationToken)
    {
        var oid = PostgreSqlDebugProtocol.Oid(unit.Identity) ?? throw PostgreSqlDebugErrors.RoutineNotFound(unit.DisplayName);
        if (_stopRequested)
        {
            throw new OperationCanceledException();
        }

        switch (_phase)
        {
            case Phase.Starting or Phase.Running:
                throw PostgreSqlDebugErrors.NotPaused();
            case Phase.Broken:
                throw PostgreSqlDebugErrors.Unavailable();
            case Phase.Paused when _hasReportedFirstStop:
                var reply = await PausedReadAsync(handle => PostgreSqlDebugProtocol.SourceStatement(_extensionSchema, handle, oid));
                if (FirstCell(reply) is { } text)
                {
                    return text;
                }

                break;
            case Phase.Ended:
                // The proxy may still be waiting on a target that returned; the target's own connection is free again.
                if (_rendezvous.IsAbandoned)
                {
                    throw PostgreSqlDebugErrors.Unavailable();
                }

                return FirstCell(await _target.QueryAsync(PostgreSqlDebugProtocol.RoutineSourceStatement(oid), null, cancellationToken))
                    ?? throw PostgreSqlDebugErrors.RoutineNotFound(unit.DisplayName);
        }

        // pldbg_get_source sends prosrc, which the catalog answers too while the proxy is idle.
        return FirstCell(await ProxyCallAsync(PostgreSqlDebugProtocol.RoutineSourceStatement(oid))) ?? throw PostgreSqlDebugErrors.RoutineNotFound(unit.DisplayName);
    }

    public async Task<IReadOnlyList<DebugFrame>> GetStackAsync(CancellationToken cancellationToken)
    {
        var reply = await PausedReadAsync(handle => PostgreSqlDebugProtocol.StackStatement(_extensionSchema, handle));
        return reply is null ? [] : [.. reply.Select(PostgreSqlDebugProtocol.Frame).OfType<DebugFrame>()];
    }

    public async Task<IReadOnlyList<DebugVariable>> GetVariablesAsync(int frameLevel, CancellationToken cancellationToken)
    {
        if (frameLevel != _selectedFrame)
        {
            if (await PausedReadAsync(handle => PostgreSqlDebugProtocol.SelectFrameStatement(_extensionSchema, handle, frameLevel)) is null)
            {
                return [];
            }

            _selectedFrame = frameLevel;
        }

        var reply = await PausedReadAsync(handle => PostgreSqlDebugProtocol.VariablesStatement(_extensionSchema, handle));
        return reply is null ? [] : [.. reply.Select(PostgreSqlDebugProtocol.Variable).OfType<DebugVariable>()];
    }

    public async Task<DebugBreakpoint?> SetBreakpointAsync(DebugBreakpoint breakpoint, CancellationToken cancellationToken)
    {
        if (PausedSession() is not { } handle)
        {
            return null;
        }

        try
        {
            return await PlaceAsync(breakpoint, handle);
        }
        catch (Exception ex) when (PostgreSqlDebugProtocol.ProxyFailure(ex) == PostgreSqlDebugProxyFailure.TargetEnded)
        {
            return null;
        }
        catch (Exception ex) when (PostgreSqlDebugProtocol.ProxyFailure(ex) == PostgreSqlDebugProxyFailure.Interrupted)
        {
            NoteInterruption();
            throw;
        }
    }

    public async Task RemoveBreakpointAsync(DebugBreakpoint breakpoint, CancellationToken cancellationToken)
    {
        if (PostgreSqlDebugProtocol.Oid(breakpoint.UnitIdentity) is { } oid)
        {
            await PausedReadAsync(handle => PostgreSqlDebugProtocol.DropBreakpointStatement(_extensionSchema, handle, oid, breakpoint.Line));
        }
    }

    public async Task<DebugStopOutcome> StopAsync()
    {
        Task stopping;
        lock (_stopLock)
        {
            if (_stopTask is null)
            {
                _stopRequested = true;
                _stopSignal.Settle();
                _stopDeadline ??= Deadline(_stopBudget);
                _stopTask = Task.Run(PerformStopAsync);
            }

            stopping = _stopTask;
        }

        await stopping;

        // A call that failed on its own connection ended only on this side; the backend may still hold its locks.
        var callEnded = _rendezvous.HasSettled && (_abortDelivered || _backendGone || !_target.HasLostConnection);
        return PostgreSqlDebugProtocol.StopOutcome(callEnded, _rendezvous.IsAbandoned, _targetProcess, _port);
    }

    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref _disposed, 1) == 1)
        {
            return;
        }

        _target.Notice -= OnTargetNotice;
        _output.Writer.TryComplete();
        _stopSignal.Settle();
        IPostgreSqlDebugConnection[] rescues;
        lock (_rescues)
        {
            rescues = [.. _rescues];
        }

        foreach (var connection in rescues.Prepend(_proxy).Prepend(_target))
        {
            await connection.DisposeAsync();
        }
    }

    private async Task<PostgreSqlDebugCallOutcome> RunTargetCallAsync(PostgreSqlDebugCall call)
    {
        PostgreSqlDebugCallOutcome outcome;
        try
        {
            outcome = new PostgreSqlDebugCallOutcome(await _target.CallAsync(call), null);
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            outcome = new PostgreSqlDebugCallOutcome(null, ex);
        }

        _target.Notice -= OnTargetNotice;
        _output.Writer.TryComplete();
        _rendezvous.Settle();
        return outcome;
    }

    private void OnTargetNotice(PostgreSqlDebugNotice notice)
    {
        if (PostgreSqlDebugProtocol.DebuggerPort(notice.MessageText) is { } port)
        {
            _rendezvous.Deliver(port);
        }
        else
        {
            _output.Writer.TryWrite(notice.Text);
        }
    }

    // A backend that may still hold its locks matters more than why the start failed.
    private async Task<Exception> StopForStartAsync(Exception otherwise) =>
        (await StopAsync()).Confirmed ? otherwise : PostgreSqlDebugErrors.TargetAbandoned(_targetProcess, _port);

    /// <summary>
    /// A cancel reaches only a call already sent, so it is repeated until the call ends or the target announces its
    /// port; from then on the target ignores a cancel and the attach and abort end it. A target that does neither by
    /// the deadline is given up, so nothing waits on it forever.
    /// </summary>
    private void CancelUntilEntered(long deadline) =>
        _ = Task.Run(async () =>
        {
            while (PostgreSqlDebugProtocol.StartCancellation(_rendezvous.HasPort, _rendezvous.HasSettled) == PostgreSqlDebugStartCancellation.CancelCall)
            {
                var remaining = Remaining(deadline);
                if (remaining <= TimeSpan.Zero)
                {
                    Trace.TraceWarning("The debug target neither ended nor reached the routine before the stop deadline.");
                    _rendezvous.Abandon();
                    return;
                }

                _target.Cancel();
                await Task.Delay(Min(CancelRetryDelay, remaining));
            }
        });

    // The call ended before the routine was entered: its arguments were refused, or the debugger could not start.
    private async Task EndBeforeEntryAsync()
    {
        var outcome = _targetCall is null ? PostgreSqlDebugCallOutcome.Cancelled : await _targetCall;
        _phase = Phase.Ended;
        _stopSignal.Settle();
        _hasReportedFirstStop = true;
        if (outcome.Error is OperationCanceledException)
        {
            throw new OperationCanceledException();
        }

        if (outcome.Error is { } error)
        {
            throw PostgreSqlDebugProtocol.StartFailure(error, _routine.Database, _routine.DisplayName);
        }

        _terminalStop = PostgreSqlDebugProtocol.End(outcome, stopRequested: false);
    }

    private async Task<DebugStop> AdvanceAsync(string statement, IReadOnlyList<DebugBreakpoint> breakpoints)
    {
        _phase = Phase.Running;
        _selectedFrame = 0;

        // The target keeps its debugger socket for the rest of its session, so when the routine returns without pausing
        // again the proxy hears of it only once that session closes. The target's own call ending is the signal instead.
        var step = _proxy.QueryAsync(statement);
        if (!await _rendezvous.AnswersFirstAsync(step))
        {
            Forget(step);
            return await TargetEndedAsync();
        }

        IReadOnlyList<IReadOnlyList<string?>> reply;
        Exception? failure = null;
        try
        {
            reply = await step;
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            reply = [];
            failure = ex;
        }

        if (failure is not null)
        {
            switch (PostgreSqlDebugProtocol.ProxyFailure(failure))
            {
                case PostgreSqlDebugProxyFailure.TargetEnded:
                    return await TargetEndedAsync();
                case PostgreSqlDebugProxyFailure.Interrupted:
                    // The target goes on to its next pause and waits for a command the session can no longer match to a
                    // reply, so it is ended the way Stop ends it.
                    NoteInterruption();
                    _endedByInterruption = !_stopRequested;
                    await EndTargetAsync();
                    return await TargetEndedAsync();
                default:
                    _phase = Phase.Broken;
                    if (!_stopRequested)
                    {
                        throw failure;
                    }

                    await EndTargetAsync();
                    return await OutcomeAfterStopAsync();
            }
        }

        _hasReportedFirstStop = true;
        if (PostgreSqlDebugProtocol.Location(reply.Count > 0 ? reply[0] : null) is not { } stop)
        {
            return await TargetEndedAsync();
        }

        _phase = Phase.Paused;
        _lastStop = stop;
        if (_stopRequested)
        {
            // The target paused before the cancel reached it, and a paused target holds a cancel until it resumes.
            await EndTargetAsync();
            return await TargetEndedAsync();
        }

        if (_handle is { } handle)
        {
            foreach (var breakpoint in breakpoints)
            {
                if (_stopRequested)
                {
                    break;
                }

                try
                {
                    await PlaceAsync(breakpoint, handle);
                }
                catch (Exception ex) when (PostgreSqlDebugProtocol.ProxyFailure(ex) == PostgreSqlDebugProxyFailure.Interrupted)
                {
                    NoteInterruption();
                    _endedByInterruption = !_stopRequested;
                    await EndTargetAsync();
                    return await TargetEndedAsync();
                }
                catch (Exception ex) when (ex is not OutOfMemoryException)
                {
                    // A breakpoint the engine refuses is simply not placed; the run goes on.
                }
            }
        }

        return _stopRequested ? await OutcomeAfterStopAsync() : new DebugStop.Paused(stop);
    }

    // pldbg_set_breakpoint accepts any line and answers t; a line with no statement never stops.
    private async Task<DebugBreakpoint?> PlaceAsync(DebugBreakpoint breakpoint, int session)
    {
        if (PostgreSqlDebugProtocol.Oid(breakpoint.UnitIdentity) is not { } oid || breakpoint.Line <= 0)
        {
            return null;
        }

        var reply = await ProxyCallAsync(PostgreSqlDebugProtocol.SetBreakpointStatement(_extensionSchema, session, oid, breakpoint.Line));
        return PostgreSqlDebugProtocol.IsTrue(FirstCell(reply)) ? breakpoint : null;
    }

    /// <summary>
    /// A read or breakpoint edit a stop overlaps throws at once. Its statement still finishes on the proxy first, and the
    /// abort queued behind it reaches the target after it; cancelling the read gains nothing and can leave part of its
    /// reply unread.
    /// </summary>
    private async Task<IReadOnlyList<IReadOnlyList<string?>>> ProxyCallAsync(string statement)
    {
        var step = _proxy.QueryAsync(statement);
        if (!await _stopSignal.AnswersFirstAsync(step))
        {
            Forget(step);
            throw new OperationCanceledException();
        }

        return await step;
    }

    private async Task<IReadOnlyList<IReadOnlyList<string?>>?> PausedReadAsync(Func<int, string> statement)
    {
        if (PausedSession() is not { } handle)
        {
            return null;
        }

        try
        {
            return await ProxyCallAsync(statement(handle));
        }
        catch (Exception ex) when (PostgreSqlDebugProtocol.ProxyFailure(ex) == PostgreSqlDebugProxyFailure.TargetEnded)
        {
            return null;
        }
        catch (Exception ex) when (PostgreSqlDebugProtocol.ProxyFailure(ex) == PostgreSqlDebugProxyFailure.Interrupted)
        {
            NoteInterruption();
            throw;
        }
    }

    // The interrupted call's reply stays unread on the proxy, so no later call could be matched to its own reply.
    private void NoteInterruption()
    {
        _phase = Phase.Broken;
        _proxyInterrupted = true;
    }

    // pldbgapi answers only while the target waits for a command; there is no session once the target is gone.
    private int? PausedSession()
    {
        if (_stopRequested)
        {
            return null;
        }

        return _phase switch
        {
            Phase.Paused when _hasReportedFirstStop => _handle,
            Phase.Ended or Phase.Broken => null,
            _ => throw PostgreSqlDebugErrors.NotPaused(),
        };
    }

    private async Task PerformStopAsync()
    {
        switch (_phase)
        {
            case Phase.Starting:
                if (_port is null)
                {
                    var deadline = CurrentDeadline();
                    CancelUntilEntered(deadline);
                    var port = await BoundedAsync(_rendezvous.PortAsync(), deadline);
                    _port = port?.Value;
                }

                if (_port is not null)
                {
                    await EndTargetAsync();
                }
                else
                {
                    await AwaitTargetEndAsync();
                }

                break;
            case Phase.Paused or Phase.Broken:
                await EndTargetAsync();
                break;
            case Phase.Running:
                // Never the proxy: cancelling a waiting proxy call desynchronizes the session. A target that paused before
                // this cancel arrived holds it, and the step in flight aborts the target instead.
                _target.Cancel();
                await AwaitTargetEndAsync();
                break;
        }

        if (_target.HasLostConnection && !_abortDelivered)
        {
            await EndBackendWithoutItsConnectionAsync();
        }

        await TargetEndedAsync();
    }

    /// <summary>
    /// A call whose own connection dropped ended only on this side: its backend may still run a statement, or wait at a
    /// pause for the proxy, which still holds it. The proxy's abort reaches it paused, a cancel from another session
    /// reaches it running, and only its absence from pg_stat_activity confirms the end.
    /// </summary>
    private async Task EndBackendWithoutItsConnectionAsync()
    {
        Forget(AbortTargetAsync());
        if (_targetProcess is not { } process)
        {
            return;
        }

        var deadline = CurrentDeadline();
        if (await BoundedAsync(OpenRescueAsync(), deadline) is not { Error: null, Value: { } rescue })
        {
            return;
        }

        await BoundedAsync(rescue.QueryAsync(PostgreSqlDebugProtocol.CancelBackendStatement(process)), deadline);
        while (!_abortDelivered)
        {
            if (await BoundedAsync(rescue.QueryAsync(PostgreSqlDebugProtocol.BackendCountStatement(process)), deadline) is not { Error: null, Value: { } reply })
            {
                return;
            }

            if (FirstCell(reply) == "0")
            {
                _backendGone = true;
                return;
            }

            var remaining = Remaining(deadline);
            if (remaining <= TimeSpan.Zero)
            {
                return;
            }

            await Task.Delay(Min(AttachRetryDelay, remaining));
        }
    }

    /// <summary>
    /// The abort is sent, not waited on: an abort to a target that already returned waits on a socket that stays open for
    /// the target's session, and the target's call ending is what counts. Without a working proxy the target may still be
    /// running a statement, which only a cancel ends before it pauses and waits for good.
    /// </summary>
    private async Task EndTargetAsync()
    {
        if (_proxyInterrupted || _phase == Phase.Broken)
        {
            _target.Cancel();
        }

        Forget(AbortTargetAsync());
        await AwaitTargetEndAsync();
    }

    // Past the deadline the target is given up rather than waited on, and the answer then says it may hold its locks.
    private async Task AwaitTargetEndAsync()
    {
        if (await BoundedAsync(Settled(), CurrentDeadline()) is null && !_rendezvous.HasSettled)
        {
            Trace.TraceWarning("The debug target was not confirmed ended before the stop deadline.");
            _rendezvous.Abandon();
        }
    }

    private async Task<bool> Settled()
    {
        await _rendezvous.Settled;
        return true;
    }

    private async Task AbortTargetAsync()
    {
        if (Interlocked.Exchange(ref _abortSent, 1) == 1)
        {
            return;
        }

        // After an interruption the same proxy still holds the target, which reads the abort at its next pause.
        if (_handle is { } handle && (_phase != Phase.Broken || _proxyInterrupted))
        {
            var sent = await BoundedAsync(_proxy.QueryAsync(PostgreSqlDebugProtocol.AbortStatement(_extensionSchema, handle)), CurrentDeadline());
            if (sent is null)
            {
                return;
            }

            if (sent.Error is null)
            {
                _abortDelivered = true;
                return;
            }

            // An interrupted abort was still written; the target reads it at its next pause while the proxy stays
            // connected, and an attach cannot reach a target the proxy still holds.
            if (PostgreSqlDebugProtocol.ProxyFailure(sent.Error) != PostgreSqlDebugProxyFailure.Broken)
            {
                return;
            }
        }

        // With the target's own connection gone its call has already settled, which ends no backend.
        await AbortByAttachingAsync(reusingProxy: _handle is null && _phase != Phase.Broken, evenAfterTheCallEnded: _target.HasLostConnection);
    }

    /// <summary>
    /// A target whose proxy is gone waits in accept() and ignores cancel and terminate; attaching to its backend number
    /// and aborting is the only way to end it. The old proxy can hold the target for a moment after its client goes, so
    /// the attach is retried until the deadline.
    /// </summary>
    private async Task AbortByAttachingAsync(bool reusingProxy, bool evenAfterTheCallEnded)
    {
        if (_port is not { } port)
        {
            return;
        }

        IPostgreSqlDebugConnection connection;
        if (reusingProxy)
        {
            connection = _proxy;
        }
        else if (await BoundedAsync(OpenRescueAsync(), CurrentDeadline()) is { Error: null, Value: { } opened })
        {
            connection = opened;
        }
        else
        {
            Trace.TraceWarning("No session opened to reach the debug target before the stop deadline.");
            return;
        }

        var deadline = CurrentDeadline();
        while (!_abortDelivered && (evenAfterTheCallEnded || !_rendezvous.HasSettled))
        {
            var ended = await BoundedAsync(AttachAndAbortAsync(connection, port), deadline);
            if (ended is null)
            {
                return;
            }

            if (ended.Error is null)
            {
                _abortDelivered = true;
                return;
            }

            var remaining = Remaining(deadline);
            if (remaining <= TimeSpan.Zero)
            {
                return;
            }

            await Task.Delay(Min(AttachRetryDelay, remaining));
        }
    }

    private async Task<bool> AttachAndAbortAsync(IPostgreSqlDebugConnection connection, int port)
    {
        var session = await AttachAsync(connection, port);
        await connection.QueryAsync(PostgreSqlDebugProtocol.AbortStatement(_extensionSchema, session));
        return true;
    }

    private async Task<int> AttachAsync(IPostgreSqlDebugConnection connection, int port)
    {
        var reply = await connection.QueryAsync(PostgreSqlDebugProtocol.AttachStatement(_extensionSchema, port));
        return int.TryParse(FirstCell(reply), NumberStyles.Integer, CultureInfo.InvariantCulture, out var session)
            ? session
            : throw PostgreSqlDebugErrors.Unavailable();
    }

    private async Task<IPostgreSqlDebugConnection> OpenRescueAsync()
    {
        var connection = await _openConnection(CancellationToken.None);
        lock (_rescues)
        {
            _rescues.Add(connection);
        }

        return connection;
    }

    private async Task<DebugStop> TargetEndedAsync()
    {
        await _rendezvous.Settled;
        _phase = Phase.Ended;
        _stopSignal.Settle();
        if (_terminalStop is { } terminal)
        {
            return terminal;
        }

        DebugStop stop;
        if (_rendezvous.IsAbandoned)
        {
            stop = PostgreSqlDebugProtocol.AbandonedStop(_targetProcess, _port);
        }
        else
        {
            var outcome = _targetCall is null ? PostgreSqlDebugCallOutcome.Cancelled : await _targetCall;
            stop = PostgreSqlDebugProtocol.End(outcome, _stopRequested, _endedByInterruption);
        }

        return Interlocked.CompareExchange(ref _terminalStop, stop, null) ?? stop;
    }

    private async Task<DebugStop> OutcomeAfterStopAsync()
    {
        if (_stopTask is { } stopping)
        {
            await stopping;
        }

        return _terminalStop ?? PostgreSqlDebugProtocol.End(PostgreSqlDebugCallOutcome.Cancelled, stopRequested: true);
    }

    private long CurrentDeadline()
    {
        lock (_stopLock)
        {
            _stopDeadline ??= Deadline(_stopBudget);
            return _stopDeadline.Value;
        }
    }

    private static long Deadline(TimeSpan budget) => Stopwatch.GetTimestamp() + (long)(budget.TotalSeconds * Stopwatch.Frequency);

    private static TimeSpan Remaining(long deadline) => Stopwatch.GetElapsedTime(Stopwatch.GetTimestamp(), deadline);

    private static TimeSpan Min(TimeSpan a, TimeSpan b) => a < b ? a : b;

    private static string? FirstCell(IReadOnlyList<IReadOnlyList<string?>>? rows) => rows is { Count: > 0 } && rows[0].Count > 0 ? rows[0][0] : null;

    /// <summary>The task's result, its error, or null when the deadline came first; the task keeps running past it.</summary>
    private static async Task<Bounded<T>?> BoundedAsync<T>(Task<T> task, long deadline)
    {
        if (!task.IsCompleted)
        {
            var remaining = Remaining(deadline);
            if (remaining <= TimeSpan.Zero || await Task.WhenAny(task, Task.Delay(remaining)) != task)
            {
                Forget(task);
                return null;
            }
        }

        try
        {
            return new Bounded<T>(await task, null);
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            return new Bounded<T>(default, ex);
        }
    }

    // A call left running past a deadline still fails later; observing it keeps that from surfacing as unobserved.
    private static void Forget(Task task) => _ = task.ContinueWith(static t => _ = t.Exception, CancellationToken.None, TaskContinuationOptions.OnlyOnFaulted, TaskScheduler.Default);

    private sealed record Bounded<T>(T? Value, Exception? Error);
}
