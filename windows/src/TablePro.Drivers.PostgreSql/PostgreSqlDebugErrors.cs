using TablePro.Core.Drivers;

namespace TablePro.Drivers.PostgreSql;

/// <summary>Everything the PL/pgSQL debugger says when it cannot go on, each with what to do about it where there is something.</summary>
internal static class PostgreSqlDebugErrors
{
    public static RoutineDebugException ExtensionMissing(string database) =>
        new($"The PL/pgSQL debugger isn't installed in \"{database}\".", "Ask a superuser to run CREATE EXTENSION pldbgapi in this database.");

    public static RoutineDebugException ServerPackageMissing() =>
        new("This server has no PL/pgSQL debugger.", "Install the pldebugger package for this PostgreSQL version on the server, then run CREATE EXTENSION pldbgapi in this database.");

    public static RoutineDebugException NotOwner(string routine) => new($"Only the owner of {routine} or a superuser can debug it.", (string?)null);

    public static RoutineDebugException SharedMemoryUnavailable() =>
        new("The server couldn't start the debugger.", "Add plugin_debugger to shared_preload_libraries and restart the server.");

    public static RoutineDebugException RoutineNotFound(string routine) => new($"{routine} no longer exists.", (string?)null);

    public static RoutineDebugException NotDebuggable() => new("Only PL/pgSQL functions and procedures can be debugged.", (string?)null);

    public static RoutineDebugException PseudoTypeParameter() => new("Routines with polymorphic or record parameters can't be debugged.", (string?)null);

    public static RoutineDebugException HidesDebuggerNotice(string value) =>
        new($"This routine sets client_min_messages to {value}, which hides the notice the debugger starts with.", "Remove SET client_min_messages from the routine to debug it.");

    public static RoutineDebugException LimitsTransactionTime(string value) =>
        new($"This routine sets transaction_timeout to {value}, which would end it while it waits at a breakpoint.", "Remove SET transaction_timeout from the routine to debug it.");

    public static RoutineDebugException TargetAbandoned(int? process, int? port) =>
        new(PostgreSqlDebugProtocol.AbandonedMessage, PostgreSqlDebugProtocol.AbandonedDetail(process, port));

    public static RoutineDebugException Unavailable() => new("This connection can't run the PL/pgSQL debugger.", (string?)null);

    public static RoutineDebugException NotPaused() => new("The routine isn't paused.", (string?)null);

    public static RoutineDebugException UnsupportedCommand() => new("The PL/pgSQL debugger can't step out of a routine.", (string?)null);

    public static RoutineDebugException NoDefault(string parameter) => new($"{parameter} has no default value.", (string?)null);

    public static RoutineDebugException DefaultNotReadable(string parameter) =>
        new($"This server can't show the default value of {parameter}, so enter a value for it.", (string?)null);

    public static RoutineDebugException NoOverloads(string routine) =>
        new($"{routine} has no PL/pgSQL overload that can be debugged.", "Only PL/pgSQL functions and procedures without polymorphic, record or trigger signatures can be debugged.");
}
