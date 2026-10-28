using TablePro.Core.Drivers;

namespace TablePro.Drivers.Oracle;

/// <summary>Everything the Oracle debugger says to the user, worded once.</summary>
internal static class OracleDebugText
{
    public const string UsingDbmsDebug = "Debugging through DBMS_DEBUG.";

    public const string RunNote = "Changes the routine makes are committed when it finishes. Stop rolls them back.";

    public const string Stopped = "Stopped. The routine's changes were rolled back.";

    public const string RoutineFailed = "The routine raised an error. Its changes were rolled back.";

    public const string ConnectionLost = "The debug session's connection closed.";

    public const string StillRunning = "TablePro couldn't confirm that the routine ended. It may still be running on the server.";

    public const string Ended = "The debug session has ended.";

    public const string Unreadable = "The database answered the debugger with data TablePro can't read.";

    public static string UnitUnreadable(string name) => $"TablePro can't read {name}. Check that this account can see its source.";

    public static string NoEntryPoints(string name) => $"{name} has no public procedure or function to start from.";

    public static string BreakpointHasNoCode(OracleDebugUnit unit, int line) => $"Line {line} of {unit.Name} has no code to stop at.";

    // Recompiling a package body discards its state in every session using it; their next call fails once with ORA-04068.
    public static string CompileForDebug(OracleDebugUnitKind kind)
    {
        const string Compile = "TablePro compiles it again with debug information (PLSQL_OPTIMIZE_LEVEL=1) and keeps its other settings. Compiling commits.";
        return kind.HasSubprograms()
            ? Compile + " Other sessions using the package lose its state, and their next call to it fails once with ORA-04068."
            : Compile;
    }

    public static RoutineDebugException MissingPrivilege(OracleMissingPrivilege missing, OracleDebugUnit unit) => missing switch
    {
        OracleMissingPrivilege.DebugConnectSession => new RoutineDebugException(
            "Debugging needs the DEBUG CONNECT SESSION privilege.",
            $"A DBA can grant it with GRANT DEBUG CONNECT SESSION TO {missing.User}."),
        _ => new RoutineDebugException(
            $"Debugging {unit.Owner}.{unit.Name} needs the DEBUG privilege on it.",
            $"A DBA can grant it with GRANT DEBUG ON {unit.Owner}.{unit.Name} TO {missing.User}, or grant DEBUG ANY PROCEDURE."),
    };

    public static string StillRunningDetail(OracleDebugSessionIdentity? identity)
    {
        const string Rollback = "Its uncommitted work rolls back when it ends.";
        if (identity is null)
        {
            return Rollback + " A user with ALTER SYSTEM can find its session in V$SESSION and end it with ALTER SYSTEM KILL SESSION.";
        }

        return identity.Serial is { } serial && OracleDbmsDebugStatements.KillSession(identity) is { } kill
            ? $"Session SID {identity.Sid}, SERIAL# {serial}. {Rollback} A user with ALTER SYSTEM can end it now with {kill}."
            : $"Session SID {identity.Sid}. {Rollback}";
    }

    public static RoutineDebugException Ambiguous(OracleDebugAmbiguity ambiguity, string subprogram) => ambiguity.Kind switch
    {
        OracleDebugAmbiguityKind.NeedsValue => new RoutineDebugException(
            ambiguity.Parameters.Count == 1
                ? $"Give {ambiguity.Parameters[0]} a value. Left at its default, the call also matches another overload of {subprogram}."
                : $"Give {string.Join(", ", ambiguity.Parameters)} values. Left at their defaults, the call also matches another overload of {subprogram}.",
            "Oracle can't tell the overloads apart without it (PLS-00307), and TablePro can't read the default to pass it."),
        _ => new RoutineDebugException(
            $"This call matches more than one overload of {subprogram}, so Oracle can't run it (PLS-00307).",
            "Debug it from a routine that calls it with arguments only this overload takes."),
    };

    public static RoutineDebugException Argument(OracleDebugArgumentException error) => error.Declarable
        ? new RoutineDebugException($"TablePro can't turn text into a {error.TypeName} value for {error.Name}.", "Pass NULL or leave it at its default.")
        : new RoutineDebugException($"TablePro can't pass any value of type {error.TypeName} to {error.Name}.", "Debug it from a routine that calls it with that value.");

    /// <summary>A start failure in the user's terms: ORA-01031 from INITIALIZE is the missing DEBUG CONNECT SESSION.</summary>
    public static Exception StartFailure(Exception error) => error switch
    {
        RoutineDebugException or OperationCanceledException => error,
        OracleDebugServerException server when OracleDebugStatements.ErrorCodes(server.Message) is [1031, ..] =>
            new RoutineDebugException("Debugging needs the DEBUG CONNECT SESSION privilege.", server.Message, server),
        OracleDebugServerException server => new RoutineDebugException("The debugger couldn't start.", server.Message, server),
        _ => Step(error),
    };

    /// <summary>A failure during a step or a read, in the user's terms.</summary>
    public static Exception Step(Exception error) => error switch
    {
        RoutineDebugException or OperationCanceledException => error,
        OracleDebugEndedException => new RoutineDebugException(Ended, (string?)null),
        FormatException => new RoutineDebugException(Unreadable, (string?)null, error),
        OracleDebugServerException server => new RoutineDebugException("The debugger couldn't finish this step.", server.Message, server),
        _ => new RoutineDebugException("The debugger couldn't finish this step.", error.Message, error),
    };
}

/// <summary>A call made after the run ended or while a stop is under way.</summary>
internal sealed class OracleDebugEndedException : Exception
{
    public OracleDebugEndedException()
        : base(OracleDebugText.Ended)
    {
    }

    public OracleDebugEndedException(string message)
        : base(message)
    {
    }

    public OracleDebugEndedException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}
