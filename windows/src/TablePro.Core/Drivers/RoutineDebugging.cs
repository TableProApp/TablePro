using System.Threading.Channels;
using TablePro.Core.Localization;
using TablePro.Core.Results;
using TablePro.Core.Schema;

namespace TablePro.Core.Drivers;

/// <summary>
/// Stepping through a stored routine with breakpoints: PL/pgSQL through the pldebugger extension, Oracle PL/SQL through
/// DBMS_DEBUG. A session that implements it is found with a type test, like the other optional features.
/// </summary>
public interface IRoutineDebugger
{
    /// <summary>
    /// The routine as something to debug, or null when it cannot be. Synchronous so a context menu can ask without I/O,
    /// which means a routine offered here may still be refused by <see cref="PrepareDebugAsync"/>.
    /// </summary>
    RoutineDebugTarget? GetDebugTarget(DatabaseObject routine);

    /// <summary>The routines in a schema that can be debugged, for a chooser.</summary>
    Task<IReadOnlyList<RoutineDebugTarget>> GetDebugTargetsAsync(string? schema, CancellationToken cancellationToken);

    /// <summary>Reads what the start dialog needs, and throws <see cref="RoutineDebugException"/> when the routine cannot be debugged.</summary>
    Task<RoutineDebugPlan> PrepareDebugAsync(RoutineDebugTarget target, CancellationToken cancellationToken);

    /// <summary>Runs the plan's preparation, such as Oracle's compile for debug, after the user agreed to it.</summary>
    Task RunPreparationAsync(RoutineDebugPreparation preparation, CancellationToken cancellationToken);

    /// <summary>
    /// Opens the connections the run needs and starts the routine. The session owns those connections and closes them
    /// when disposed. Cancelling ends the routine as <see cref="IRoutineDebugSession.StopAsync"/> would, then throws.
    /// </summary>
    Task<IRoutineDebugSession> StartDebugAsync(RoutineDebugRequest request, CancellationToken cancellationToken);
}

/// <summary>
/// One run of a routine under the debugger. The caller never overlaps two calls, except <see cref="StopAsync"/>, which may
/// arrive while any other call is still running: that call then ends promptly, a waiting step with
/// <see cref="DebugStop.Finished"/> or <see cref="DebugStop.Failed"/>, never a pause, and a read by throwing.
/// </summary>
public interface IRoutineDebugSession : IAsyncDisposable
{
    IReadOnlySet<DebugCommand> SupportedCommands { get; }

    /// <summary>Notices and server output the routine produces, completed when the run ends.</summary>
    ChannelReader<string> Output { get; }

    Task<DebugStop> FirstStopAsync(CancellationToken cancellationToken);

    Task<DebugStop> PerformAsync(DebugCommand command, CancellationToken cancellationToken);

    /// <summary>The text that <see cref="DebugLocation.Line"/> numbers, one-based.</summary>
    Task<string> GetSourceAsync(DebugUnit unit, CancellationToken cancellationToken);

    Task<IReadOnlyList<DebugFrame>> GetStackAsync(CancellationToken cancellationToken);

    Task<IReadOnlyList<DebugVariable>> GetVariablesAsync(int frameLevel, CancellationToken cancellationToken);

    /// <summary>The breakpoint as the engine placed it, whose line may move to the next executable one; null when it cannot be set.</summary>
    Task<DebugBreakpoint?> SetBreakpointAsync(DebugBreakpoint breakpoint, CancellationToken cancellationToken);

    Task RemoveBreakpointAsync(DebugBreakpoint breakpoint, CancellationToken cancellationToken);

    /// <summary>
    /// Ends the routine and rolls back its open transaction, whatever state it is in, and says whether that was confirmed.
    /// Returns within <see cref="RoutineDebugging.StopBudget"/>; the caller disposes the session soon after.
    /// </summary>
    Task<DebugStopOutcome> StopAsync();
}

public static class RoutineDebugging
{
    /// <summary>How long a session's stop may take before the caller closes its connections anyway.</summary>
    public static readonly TimeSpan StopBudget = TimeSpan.FromSeconds(3);
}

/// <summary>
/// A routine to debug. Its identity is the engine's own key: an oid on PostgreSQL, the unit's type, owner and name on
/// Oracle, or empty when the routine is found by name.
/// </summary>
public sealed record RoutineDebugTarget(string Identity, ObjectName Name, string DisplayName, string KindDisplayName);

/// <summary>
/// What the start dialog offers. <c>MayWrite</c> means the routine may change data, so a Safe Mode that blocks writes
/// refuses the run; <c>Note</c> says what happens to its changes when it runs to the end.
/// </summary>
public sealed record RoutineDebugPlan(
    RoutineDebugTarget Target,
    IReadOnlyList<DebugEntryPoint> EntryPoints,
    bool MayWrite,
    RoutineDebugPreparation? Preparation = null,
    string? Note = null);

/// <summary>One way into the routine: an overload on PostgreSQL, a public subprogram of a package on Oracle.</summary>
public sealed record DebugEntryPoint(string Identity, string DisplayName, IReadOnlyList<DebugParameter> Parameters);

public sealed record DebugParameter(string Name, string TypeName, DebugParameterMode Mode, bool HasDefault)
{
    public bool TakesValue => Mode != DebugParameterMode.Output;
}

public enum DebugParameterMode
{
    Input,
    Output,
    InputOutput,
    Variadic,
}

/// <summary>Statements to run, after the user confirms, before the routine can be debugged.</summary>
public sealed record RoutineDebugPreparation(string Message, string? InformativeText, string ActionTitle, IReadOnlyList<string> Statements);

public sealed record RoutineDebugRequest(DebugEntryPoint EntryPoint, IReadOnlyList<DebugArgument> Arguments, IReadOnlyList<DebugBreakpoint> Breakpoints);

public sealed record DebugArgument(string ParameterName, DebugArgumentValue Value);

/// <summary>What a parameter is given: typed text, SQL NULL, or the routine's own default.</summary>
public abstract record DebugArgumentValue
{
    public static readonly DebugArgumentValue Null = new NullValue();

    public static readonly DebugArgumentValue Default = new DefaultValue();

    public static DebugArgumentValue FromText(string text) => new TextValue(text);

    public sealed record TextValue(string Text) : DebugArgumentValue;

    public sealed record NullValue : DebugArgumentValue;

    public sealed record DefaultValue : DebugArgumentValue;
}

public enum DebugCommand
{
    Continue,
    StepOver,
    StepInto,
    StepOut,
}

/// <summary>Where a run is after a step: paused at a line, finished with its result, or failed.</summary>
public abstract record DebugStop
{
    public sealed record Paused(DebugLocation Location) : DebugStop;

    /// <param name="Result">The routine's result and output parameters, or null when it returned nothing to show.</param>
    public sealed record Finished(ResultSet? Result) : DebugStop;

    public sealed record Failed(string Message, string? Detail) : DebugStop;
}

/// <summary>Whether a stop confirmed the routine ended; when not, the message names it and how to end it.</summary>
public sealed record DebugStopOutcome(bool Confirmed, string? Message = null, string? Detail = null)
{
    public static readonly DebugStopOutcome Ended = new(true);

    public static DebugStopOutcome Unconfirmed(string message, string? detail) => new(false, message, detail);
}

/// <summary>A unit of source the debugger can stop in: a function, a procedure, a package body.</summary>
public sealed record DebugUnit(string Identity, string DisplayName);

/// <summary>A line of a unit, one-based in the text <see cref="IRoutineDebugSession.GetSourceAsync"/> returns for it.</summary>
public sealed record DebugLocation(DebugUnit Unit, int Line);

public sealed record DebugBreakpoint(string UnitIdentity, int Line);

public sealed record DebugFrame(int Level, DebugLocation? Location, string? Description);

/// <summary>A variable of a paused frame; a null value is SQL NULL.</summary>
public sealed record DebugVariable(string Name, DebugVariableKind Kind, string? TypeName, string? Value, bool IsConstant);

public enum DebugVariableKind
{
    Argument,
    Local,
    Package,
}

/// <summary>A failure worded for the user, with an optional second line saying what to do about it.</summary>
public sealed class RoutineDebugException : Exception
{
    public RoutineDebugException()
        : this(CoreStrings.Get("Debugger/DebuggerFailed"))
    {
    }

    public RoutineDebugException(string message)
        : base(message)
    {
    }

    public RoutineDebugException(string message, Exception innerException)
        : base(message, innerException)
    {
    }

    public RoutineDebugException(string message, string? detail, Exception? innerException = null)
        : base(message, innerException)
    {
        Detail = detail;
    }

    public string? Detail { get; }
}
