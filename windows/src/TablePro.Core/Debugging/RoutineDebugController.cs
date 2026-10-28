using System.Diagnostics;
using TablePro.Core.Drivers;
using TablePro.Core.Results;

namespace TablePro.Core.Debugging;

public enum DebugRunState
{
    Preparing,
    Starting,
    Running,
    Paused,
    Finished,
    Failed,
    Stopped,
}

/// <summary>What the start dialog chose: the way into the routine and the value of each parameter.</summary>
public sealed record RoutineDebugStartChoice(DebugEntryPoint EntryPoint, IReadOnlyList<DebugArgument> Arguments);

/// <summary>
/// One debug run, from the preparation question to the end. Session calls never overlap except
/// <see cref="IRoutineDebugSession.StopAsync"/>: every other call waits its turn behind the previous one, so a step never
/// races the reads of the pause before it.
/// </summary>
/// <remarks>
/// It holds no thread of its own. Created and driven from the UI thread, every continuation comes back there, which is
/// why <see cref="Changed"/> can be handled without dispatching; nothing here uses <c>ConfigureAwait(false)</c>.
/// </remarks>
public sealed class RoutineDebugController : IDisposable
{
    public const int OutputLineLimit = 5_000;

    public const string StopNotConfirmed = "The debugger didn't confirm the stop. The routine may still be running on the server.";

    public const string FinishedBeforeStop = "The routine finished before the stop reached it.";

    // Output a driver relays as the routine completes (Oracle's DBMS_OUTPUT) arrives just after the last step.
    private static readonly TimeSpan OutputDrainLimit = TimeSpan.FromSeconds(1);

    // Disposing closes the run's connections; one that hangs is not worth freezing the tab for.
    private static readonly TimeSpan DisposeLimit = TimeSpan.FromSeconds(5);

    private readonly IRoutineDebugger _debugger;
    private readonly Func<RoutineDebugPreparation, CancellationToken, Task<bool>> _confirmPreparation;
    private readonly TimeSpan _stopLimit;
    private readonly Dictionary<string, HashSet<int>> _breakpoints = new(StringComparer.Ordinal);
    private readonly Dictionary<string, HashSet<int>> _placed = new(StringComparer.Ordinal);
    private readonly Dictionary<string, string> _sources = new(StringComparer.Ordinal);
    private readonly List<string> _output = [];
    private readonly TaskCompletionSource _ended = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly CancellationTokenSource _questionCancellation = new();
    private readonly CancellationTokenSource _outputCancellation = new();

    private IRoutineDebugSession? _session;
    private Task<IRoutineDebugSession>? _startTask;
    private CancellationTokenSource? _startCancellation;
    private Task? _preparationTask;
    private CancellationTokenSource? _preparationCancellation;
    private Task? _lastOperation;
    private Task? _stopTask;
    private Task<DebugStopOutcome>? _targetStop;
    private Task? _outputTask;
    private long? _stopDeadline;
    private string? _unconfirmedStop;
    private string? _stopMessage;
    private int _pauseGeneration;
    private bool _isEnding;
    private bool _disposed;

    public RoutineDebugController(
        IRoutineDebugger debugger,
        RoutineDebugPlan plan,
        RoutineDebugStartChoice choice,
        Func<RoutineDebugPreparation, CancellationToken, Task<bool>> confirmPreparation,
        TimeSpan? stopLimit = null)
    {
        _debugger = debugger;
        Plan = plan;
        Choice = choice;
        _confirmPreparation = confirmPreparation;
        _stopLimit = stopLimit ?? TimeSpan.FromSeconds(5);
    }

    /// <summary>Raised after any observable change, on the thread that drives the controller.</summary>
    public event EventHandler? Changed;

    /// <summary>The user declined the preparation, so the run has nothing to show and its tab can close.</summary>
    public event EventHandler? Declined;

    public RoutineDebugPlan Plan { get; }

    public RoutineDebugStartChoice Choice { get; }

    public DebugRunState State { get; private set; } = DebugRunState.Preparing;

    public DebugLocation? PausedLocation { get; private set; }

    /// <summary>The routine's result once it finished, or null when it returned nothing to show.</summary>
    public ResultSet? Result { get; private set; }

    /// <summary>Why a failed run failed, or the driver's own words for a stopped one.</summary>
    public string? Message { get; private set; }

    public bool IsStopping { get; private set; }

    public bool HasEnded { get; private set; }

    public IReadOnlySet<DebugCommand> SupportedCommands { get; private set; } = new HashSet<DebugCommand>();

    public IReadOnlyList<DebugFrame> Frames { get; private set; } = [];

    public int? SelectedFrameLevel { get; private set; }

    /// <summary>The frame whose source and variables are on screen; they always change together.</summary>
    public int? DisplayedFrameLevel { get; private set; }

    /// <summary>False while a pause's stack is still loading, when the list shows the previous one, which cannot be chosen from.</summary>
    public bool StackIsCurrent { get; private set; }

    public IReadOnlyList<DebugVariable> Variables { get; private set; } = [];

    public IReadOnlyList<string> OutputLines => _output;

    public DebugUnit? DisplayedUnit { get; private set; }

    public string? InspectionError { get; private set; }

    /// <summary>The caret's line in the source on screen, which Toggle Breakpoint acts on.</summary>
    public int? CursorLine { get; set; }

    public string? UnconfirmedStop => _unconfirmedStop;

    public bool IsTerminal => State is DebugRunState.Finished or DebugRunState.Failed or DebugRunState.Stopped;

    public bool CanStop => !_isEnding && !IsStopping;

    public bool HasBreakpoints => _breakpoints.Values.Any(lines => lines.Count > 0);

    public bool CanToggleBreakpoint => !_isEnding && DisplayedUnit is not null && CursorLine is not null;

    public bool CanRemoveAllBreakpoints => !_isEnding && HasBreakpoints;

    public string DisplayedSource => DisplayedUnit is { } unit && _sources.TryGetValue(unit.Identity, out var text) ? text : string.Empty;

    public IReadOnlySet<int> DisplayedBreakpointLines =>
        DisplayedUnit is { } unit && _breakpoints.TryGetValue(unit.Identity, out var lines) ? lines : new HashSet<int>();

    /// <summary>The paused frame's location, or the chosen frame's once one is chosen.</summary>
    public DebugLocation? CurrentLocation
    {
        get
        {
            if (PausedLocation is not { } paused || State != DebugRunState.Paused)
            {
                return null;
            }

            return Frames.FirstOrDefault(f => f.Level == DisplayedFrameLevel)?.Location ?? paused;
        }
    }

    /// <summary>The line to highlight in the source on screen, or null when the run is not stopped in it.</summary>
    public int? ExecutionLine =>
        CurrentLocation is { } location && location.Unit.Identity == DisplayedUnit?.Identity ? location.Line : null;

    public string StatusText
    {
        get
        {
            if (IsStopping && !HasEnded)
            {
                return "Stopping…";
            }

            return State switch
            {
                DebugRunState.Preparing => "Preparing…",
                DebugRunState.Starting => "Starting…",
                DebugRunState.Running => "Running…",
                DebugRunState.Paused when PausedLocation is { } location => $"Paused at line {location.Line} in {location.Unit.DisplayName}",
                DebugRunState.Paused => "Paused",
                DebugRunState.Finished => "Finished",
                DebugRunState.Failed => Message ?? "Failed",
                _ => Message ?? "Stopped",
            };
        }
    }

    public IReadOnlyDictionary<string, IReadOnlySet<int>> Breakpoints =>
        _breakpoints.ToDictionary(p => p.Key, p => (IReadOnlySet<int>)p.Value, StringComparer.Ordinal);

    public bool CanPerform(DebugCommand command) =>
        !IsStopping && State == DebugRunState.Paused && SupportedCommands.Contains(command);

    public Task WaitUntilEndedAsync() => _ended.Task;

    public void Start()
    {
        if (_lastOperation is not null || _isEnding)
        {
            return;
        }

        _lastOperation = RunAsync();
    }

    public void Perform(DebugCommand command)
    {
        if (!CanPerform(command) || _session is not { } session)
        {
            return;
        }

        SetState(DebugRunState.Running);
        Enqueue(async () =>
        {
            if (IsStopping)
            {
                return;
            }

            // An edit made while the pause was still loading had its own sync skipped once this left the pause.
            await SyncBreakpointsAsync(session);
            if (IsStopping)
            {
                return;
            }

            await RunStepAsync(ct => session.PerformAsync(command, ct));
        });
    }

    /// <summary>
    /// Every way a run is stopped comes here: Stop, its tab closing, the window closing, a disconnect. The session hears
    /// it at once, even over a read or a step still running, which the driver then ends itself.
    /// </summary>
    public void Stop()
    {
        if (!CanStop)
        {
            return;
        }

        IsStopping = true;
        var deadline = StartStopDeadline();
        RaiseChanged();
        TryCancel(_questionCancellation);
        if (_session is { } session)
        {
            _stopTask = StopSessionAsync(session);
        }
        else if (_startTask is { } start)
        {
            _stopTask = CancelStartAsync(start, deadline);
        }
        else if (_preparationTask is { } preparation)
        {
            _stopTask = CancelPreparationAsync(preparation, deadline);
        }
        else if (_lastOperation is null)
        {
            _stopTask = EndAsync(DebugRunState.Stopped, null);
        }

        // Otherwise the preparation question is up or the run is between two steps, and it ends itself as stopped at
        // its next check.
    }

    public void ToggleBreakpointAtCursor()
    {
        if (CanToggleBreakpoint && CursorLine is { } line)
        {
            ToggleBreakpoint(line);
        }
    }

    public void ToggleBreakpoint(int line)
    {
        if (DisplayedUnit is not { } unit || line <= 0 || _isEnding)
        {
            return;
        }

        var lines = Lines(_breakpoints, unit.Identity);
        if (!lines.Remove(line))
        {
            lines.Add(line);
        }

        RaiseChanged();
        ScheduleBreakpointSync();
    }

    public void RemoveAllBreakpoints()
    {
        if (!CanRemoveAllBreakpoints)
        {
            return;
        }

        _breakpoints.Clear();
        RaiseChanged();
        ScheduleBreakpointSync();
    }

    public void SelectFrame(int level)
    {
        if (_session is not { } session || State != DebugRunState.Paused || !StackIsCurrent || SelectedFrameLevel == level
            || Frames.FirstOrDefault(f => f.Level == level) is not { } frame)
        {
            return;
        }

        SelectedFrameLevel = level;
        RaiseChanged();
        var generation = _pauseGeneration;
        Enqueue(async () =>
        {
            if (!IsCurrentFrame(level, generation))
            {
                return;
            }

            try
            {
                if (frame.Location?.Unit is { } unit)
                {
                    await LoadSourceAsync(unit, session);
                }

                if (!IsCurrentFrame(level, generation))
                {
                    return;
                }

                var values = await session.GetVariablesAsync(level, CancellationToken.None);
                if (IsCurrentFrame(level, generation))
                {
                    ShowFrame(level, frame.Location?.Unit, values);
                }
            }
            catch (Exception ex) when (ex is not OutOfMemoryException)
            {
                if (!IsStopping)
                {
                    InspectionError = MessageOf(ex);
                    RaiseChanged();
                }
            }
        });
    }

    public static string MessageOf(Exception exception) =>
        exception is RoutineDebugException debug ? Join(debug.Message, debug.Detail) : exception.Message;

    public static string Join(string? message, string? detail) =>
        string.IsNullOrEmpty(detail) ? message ?? string.Empty : string.IsNullOrEmpty(message) ? detail : message + "\n" + detail;

    private async Task RunAsync()
    {
        // A stop that landed before this ran found nothing to cancel, so nothing may be asked or opened.
        if (IsStopping)
        {
            await EndAsync(DebugRunState.Stopped, null);
            return;
        }

        if (Plan.Preparation is { } preparation && !await PrepareAsync(preparation))
        {
            return;
        }

        if (IsStopping)
        {
            await EndAsync(DebugRunState.Stopped, null);
            return;
        }

        SetState(DebugRunState.Starting);
        var request = new RoutineDebugRequest(
            Choice.EntryPoint,
            Choice.Arguments,
            [.. _breakpoints.SelectMany(p => p.Value.Order().Select(line => new DebugBreakpoint(p.Key, line)))]);
        _startCancellation = new CancellationTokenSource();
        IRoutineDebugSession session;
        try
        {
            _startTask = _debugger.StartDebugAsync(request, _startCancellation.Token);
            session = await _startTask;
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            _startTask = null;

            // A cancelled start throws something else only when it could not confirm its routine ended.
            if (IsStopping && ex is not OperationCanceledException)
            {
                _unconfirmedStop = MessageOf(ex);
            }

            await EndAsync(IsStopping ? DebugRunState.Stopped : DebugRunState.Failed, IsStopping ? null : MessageOf(ex));
            return;
        }

        _startTask = null;
        if (IsStopping || _isEnding)
        {
            // Stopped while starting: a session that came back anyway is ended before its connections close.
            await EndTargetAsync(session);
            if (_isEnding)
            {
                await DisposeAsync(session);
            }
            else
            {
                _session = session;
                await EndAsync(DebugRunState.Stopped, null);
            }

            return;
        }

        _session = session;
        foreach (var breakpoint in request.Breakpoints)
        {
            Lines(_placed, breakpoint.UnitIdentity).Add(breakpoint.Line);
        }

        SupportedCommands = session.SupportedCommands;
        _outputTask = ReadOutputAsync(session, _outputCancellation.Token);
        await RunStepAsync(ct => session.FirstStopAsync(ct));
    }

    private async Task<bool> PrepareAsync(RoutineDebugPreparation preparation)
    {
        bool confirmed;
        try
        {
            confirmed = await _confirmPreparation(preparation, _questionCancellation.Token);
        }
        catch (OperationCanceledException)
        {
            confirmed = false;
        }

        if (!confirmed)
        {
            var declined = !IsStopping;
            await EndAsync(DebugRunState.Stopped, null);
            if (declined)
            {
                Declined?.Invoke(this, EventArgs.Empty);
            }

            return false;
        }

        if (IsStopping)
        {
            await EndAsync(DebugRunState.Stopped, null);
            return false;
        }

        _preparationCancellation = new CancellationTokenSource();
        try
        {
            _preparationTask = _debugger.RunPreparationAsync(preparation, _preparationCancellation.Token);
            await _preparationTask;
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            _preparationTask = null;
            await EndAsync(IsStopping ? DebugRunState.Stopped : DebugRunState.Failed, IsStopping ? null : MessageOf(ex));
            return false;
        }

        _preparationTask = null;
        if (IsStopping)
        {
            await EndAsync(DebugRunState.Stopped, null);
            return false;
        }

        return true;
    }

    private async Task RunStepAsync(Func<CancellationToken, Task<DebugStop>> step)
    {
        DebugStop outcome;
        try
        {
            outcome = await step(CancellationToken.None);
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            if (IsStopping || _session is not { } session)
            {
                return;
            }

            // The step's outcome is unknown, so the routine is ended before its connections close.
            await EndTargetAsync(session);
            await EndAsync(DebugRunState.Failed, MessageOf(ex));
            return;
        }

        // A stop in flight owns the ending; the waiting step's own words become the status once the stop is confirmed.
        if (IsStopping)
        {
            switch (outcome)
            {
                case DebugStop.Failed failed:
                    AnswerStop(Join(failed.Message, failed.Detail));
                    break;
                case DebugStop.Finished:
                    AnswerStop(FinishedBeforeStop);
                    break;
            }

            return;
        }

        switch (outcome)
        {
            case DebugStop.Paused paused:
                _pauseGeneration++;
                SelectedFrameLevel = null;
                DisplayedFrameLevel = null;
                StackIsCurrent = false;

                // The last pause's values would read as this one's until the new ones load, or for good if they fail.
                Variables = [];
                InspectionError = null;
                PausedLocation = paused.Location;
                SetState(DebugRunState.Paused);
                await InspectAsync(paused.Location, _pauseGeneration);
                break;
            case DebugStop.Finished finished:
                await EndAsync(DebugRunState.Finished, null, finished.Result);
                break;
            case DebugStop.Failed failed:
                // A routine the driver gave up on may still run: its stop says so, and may still end it.
                if (_session is { } session)
                {
                    await EndTargetAsync(session);
                }

                await EndAsync(DebugRunState.Failed, Join(failed.Message, failed.Detail));
                break;
        }
    }

    private async Task InspectAsync(DebugLocation location, int generation)
    {
        if (_session is not { } session)
        {
            return;
        }

        DisplayedUnit = location.Unit;
        RaiseChanged();
        await SyncBreakpointsAsync(session);
        if (!IsCurrentPause(generation))
        {
            return;
        }

        try
        {
            await LoadSourceAsync(location.Unit, session);
            if (!IsCurrentPause(generation))
            {
                return;
            }

            var stack = await session.GetStackAsync(CancellationToken.None);
            if (!IsCurrentPause(generation))
            {
                return;
            }

            Frames = stack;
            var level = stack.Count > 0 ? stack[0].Level : 0;
            SelectedFrameLevel = level;
            StackIsCurrent = true;
            RaiseChanged();
            var values = await session.GetVariablesAsync(level, CancellationToken.None);
            if (IsCurrentFrame(level, generation))
            {
                ShowFrame(level, location.Unit, values);
            }
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            if (!IsStopping)
            {
                InspectionError = MessageOf(ex);
                RaiseChanged();
            }
        }
    }

    private async Task LoadSourceAsync(DebugUnit unit, IRoutineDebugSession session)
    {
        if (!_sources.ContainsKey(unit.Identity))
        {
            _sources[unit.Identity] = await session.GetSourceAsync(unit, CancellationToken.None);
        }
    }

    private void ShowFrame(int level, DebugUnit? unit, IReadOnlyList<DebugVariable> values)
    {
        if (unit is not null)
        {
            DisplayedUnit = unit;
        }

        Variables = values;
        DisplayedFrameLevel = level;
        RaiseChanged();
    }

    private void ScheduleBreakpointSync()
    {
        // While running the engine may not take a breakpoint, so edits wait for the next pause.
        if (_session is not { } session || State != DebugRunState.Paused || IsStopping)
        {
            return;
        }

        Enqueue(async () =>
        {
            if (State == DebugRunState.Paused && !IsStopping)
            {
                await SyncBreakpointsAsync(session);
            }
        });
    }

    private async Task SyncBreakpointsAsync(IRoutineDebugSession session)
    {
        var units = _breakpoints.Keys.Union(_placed.Keys).Order(StringComparer.Ordinal).ToArray();
        foreach (var unit in units)
        {
            var wanted = _breakpoints.TryGetValue(unit, out var w) ? w.ToHashSet() : [];
            var placed = _placed.TryGetValue(unit, out var p) ? p.ToHashSet() : [];
            foreach (var line in placed.Except(wanted).Order())
            {
                if (IsStopping)
                {
                    return;
                }

                try
                {
                    await session.RemoveBreakpointAsync(new DebugBreakpoint(unit, line), CancellationToken.None);
                    Lines(_placed, unit).Remove(line);
                }
                catch (Exception ex) when (ex is not OutOfMemoryException)
                {
                    // A stop ends the call on purpose; that is no failure to show.
                    if (IsStopping)
                    {
                        return;
                    }

                    Lines(_breakpoints, unit).Add(line);
                    InspectionError = MessageOf(ex);
                    RaiseChanged();
                }
            }

            foreach (var line in wanted.Except(placed).Order())
            {
                if (IsStopping)
                {
                    return;
                }

                try
                {
                    var result = await session.SetBreakpointAsync(new DebugBreakpoint(unit, line), CancellationToken.None);
                    if (result is not null)
                    {
                        Lines(_placed, result.UnitIdentity).Add(result.Line);
                    }

                    // Removed while the request was out: the server's breakpoint stays placed but unwanted, so the next
                    // sync takes it off instead of the marker coming back.
                    if (!_breakpoints.TryGetValue(unit, out var current) || !current.Remove(line))
                    {
                        continue;
                    }

                    if (result is not null)
                    {
                        Lines(_breakpoints, result.UnitIdentity).Add(result.Line);
                    }

                    RaiseChanged();
                }
                catch (Exception ex) when (ex is not OutOfMemoryException)
                {
                    if (IsStopping)
                    {
                        return;
                    }

                    Lines(_breakpoints, unit).Remove(line);
                    InspectionError = MessageOf(ex);
                    RaiseChanged();
                }
            }
        }
    }

    private async Task StopSessionAsync(IRoutineDebugSession session)
    {
        await EndTargetAsync(session);
        await EndAsync(DebugRunState.Stopped, null);
    }

    /// <summary>
    /// The only place a session hears its stop, and only once, shared by everything that ends it. Returns when the
    /// driver answers or at the deadline, whichever comes first.
    /// </summary>
    private async Task EndTargetAsync(IRoutineDebugSession session)
    {
        var deadline = StartStopDeadline();
        _targetStop ??= StopSafelyAsync(session);
        if (!await WaitAsync(_targetStop, deadline))
        {
            _unconfirmedStop = StopNotConfirmed;
            return;
        }

        var outcome = await _targetStop;
        if (!outcome.Confirmed)
        {
            _unconfirmedStop = Join(outcome.Message, outcome.Detail);
        }
    }

    private static async Task<DebugStopOutcome> StopSafelyAsync(IRoutineDebugSession session)
    {
        try
        {
            return await session.StopAsync();
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            return DebugStopOutcome.Unconfirmed(StopNotConfirmed, MessageOf(ex));
        }
    }

    // The routine may already be running before the start returns. Cancelling makes the driver end it, and a session it
    // returns anyway is stopped within the same deadline; one that never answers is given up then.
    private async Task CancelStartAsync(Task<IRoutineDebugSession> start, long deadline)
    {
        TryCancel(_startCancellation);
        if (await WaitAsync(start, deadline))
        {
            return;
        }

        _unconfirmedStop = StopNotConfirmed;
        await EndAsync(DebugRunState.Stopped, null);
    }

    // A statement already sent cannot be called back: the run waits for it until the deadline, then ends stopped and
    // never goes on to start the session.
    private async Task CancelPreparationAsync(Task preparation, long deadline)
    {
        TryCancel(_preparationCancellation);
        if (!await WaitAsync(preparation, deadline))
        {
            await EndAsync(DebugRunState.Stopped, null);
        }
    }

    private void AnswerStop(string message)
    {
        _stopMessage = message;
        if (HasEnded && State == DebugRunState.Stopped && Message is null)
        {
            Message = message;
            RaiseChanged();
        }
    }

    private async Task EndAsync(DebugRunState final, string? message, ResultSet? result = null)
    {
        if (_isEnding)
        {
            return;
        }

        _isEnding = true;

        // A run that ended by itself may still have output on its way; a stopped one keeps what already arrived.
        if (!IsStopping && _outputTask is { } output && final is DebugRunState.Finished or DebugRunState.Failed)
        {
            await Task.WhenAny(output, Task.Delay(OutputDrainLimit));
        }

        if (_session is { } session)
        {
            await DisposeAsync(session);
        }

        TryCancel(_outputCancellation);

        // Read after the wait: the waiting step's answer to the stop can land while the connections close.
        if (final == DebugRunState.Stopped && message is null)
        {
            message = _unconfirmedStop ?? _stopMessage;
        }
        else if (final == DebugRunState.Failed && _unconfirmedStop is { } unconfirmed && unconfirmed != message)
        {
            message = Join(message, unconfirmed);
        }

        Result = result;
        Message = message;
        HasEnded = true;
        SetState(final);
        _ended.TrySetResult();
    }

    private static async Task DisposeAsync(IRoutineDebugSession session)
    {
        try
        {
            await Task.WhenAny(session.DisposeAsync().AsTask(), Task.Delay(DisposeLimit));
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            Trace.TraceWarning("Closing a debug session failed: {0}", ex.Message);
        }
    }

    private async Task ReadOutputAsync(IRoutineDebugSession session, CancellationToken cancellationToken)
    {
        try
        {
            await foreach (var line in session.Output.ReadAllAsync(cancellationToken))
            {
                _output.Add(line);
                if (_output.Count > OutputLineLimit)
                {
                    _output.RemoveRange(0, _output.Count - OutputLineLimit);
                }

                RaiseChanged();
            }
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            Trace.TraceWarning("Reading debug output failed: {0}", ex.Message);
        }
    }

    /// <summary>Releases the run's cancellation sources. Call it once the run has ended; a run still going is stopped first.</summary>
    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        Stop();
        _disposed = true;
        _questionCancellation.Dispose();
        _outputCancellation.Dispose();
        _startCancellation?.Dispose();
        _preparationCancellation?.Dispose();
    }

    private void TryCancel(CancellationTokenSource? source)
    {
        if (_disposed || source is null)
        {
            return;
        }

        try
        {
            source.Cancel();
        }
        catch (AggregateException ex)
        {
            // A callback registered on the token threw; the cancellation itself still happened.
            Trace.TraceWarning("A debug cancellation callback failed: {0}", ex.InnerException?.Message);
        }
    }

    private void Enqueue(Func<Task> operation) => _lastOperation = ChainAsync(_lastOperation, operation);

    private static async Task ChainAsync(Task? previous, Func<Task> operation)
    {
        if (previous is not null)
        {
            await previous;
        }

        await operation();
    }

    private bool IsCurrentPause(int generation) => generation == _pauseGeneration && State == DebugRunState.Paused && !IsStopping;

    private bool IsCurrentFrame(int level, int generation) => IsCurrentPause(generation) && SelectedFrameLevel == level;

    private long StartStopDeadline()
    {
        _stopDeadline ??= Stopwatch.GetTimestamp() + (long)(_stopLimit.TotalSeconds * Stopwatch.Frequency);
        return _stopDeadline.Value;
    }

    private static async Task<bool> WaitAsync(Task task, long deadline)
    {
        var remaining = Stopwatch.GetElapsedTime(Stopwatch.GetTimestamp(), deadline);
        if (task.IsCompleted)
        {
            return true;
        }

        if (remaining <= TimeSpan.Zero)
        {
            return false;
        }

        return await Task.WhenAny(task, Task.Delay(remaining)) == task;
    }

    private void SetState(DebugRunState state)
    {
        State = state;
        RaiseChanged();
    }

    private void RaiseChanged() => Changed?.Invoke(this, EventArgs.Empty);

    private static HashSet<int> Lines(Dictionary<string, HashSet<int>> map, string unit)
    {
        if (!map.TryGetValue(unit, out var lines))
        {
            lines = [];
            map[unit] = lines;
        }

        return lines;
    }
}
