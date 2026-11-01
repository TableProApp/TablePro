using TablePro.Core.Drivers;
using TablePro.Drivers.Oracle.Localization;

namespace TablePro.Drivers.Oracle;

/// <summary>
/// Everything the Oracle debugger says to the user, worded once in the Oracle resources. Properties rather than
/// constants, so each message is read in the UI language at the moment it is shown.
/// </summary>
internal static class OracleDebugText
{
    public static string UsingDbmsDebug => OracleStrings.Get("Oracle/UsingDbmsDebug");

    public static string RunNote => OracleStrings.Get("Oracle/RunNote");

    public static string Stopped => OracleStrings.Get("Oracle/Stopped");

    public static string RoutineFailed => OracleStrings.Get("Oracle/RoutineFailed");

    public static string ConnectionLost => OracleStrings.Get("Oracle/ConnectionLost");

    public static string StillRunning => OracleStrings.Get("Oracle/StillRunning");

    public static string Ended => OracleStrings.Get("Oracle/Ended");

    public static string Unreadable => OracleStrings.Get("Oracle/Unreadable");

    public static string UnitUnreadable(string name) => OracleStrings.Format("Oracle/UnitUnreadable", name);

    public static string NoEntryPoints(string name) => OracleStrings.Format("Oracle/NoEntryPoints", name);

    public static string BreakpointHasNoCode(OracleDebugUnit unit, int line) => OracleStrings.Format("Oracle/BreakpointHasNoCode", line, unit.Name);

    // Recompiling a package body discards its state in every session using it; their next call fails once with ORA-04068.
    public static string CompileForDebug(OracleDebugUnitKind kind) =>
        kind.HasSubprograms() ? OracleStrings.Get("Oracle/CompileForDebugPackage") : OracleStrings.Get("Oracle/CompileForDebug");

    public static RoutineDebugException MissingPrivilege(OracleMissingPrivilege missing, OracleDebugUnit unit) => missing switch
    {
        OracleMissingPrivilege.DebugConnectSession => new RoutineDebugException(
            OracleStrings.Get("Oracle/NeedsDebugConnectSession"),
            OracleStrings.Format("Oracle/GrantDebugConnectSession", missing.User)),
        _ => new RoutineDebugException(
            OracleStrings.Format("Oracle/NeedsDebugPrivilege", $"{unit.Owner}.{unit.Name}"),
            OracleStrings.Format("Oracle/GrantDebug", $"{unit.Owner}.{unit.Name}", missing.User)),
    };

    public static string StillRunningDetail(OracleDebugSessionIdentity? identity)
    {
        if (identity is null)
        {
            return OracleStrings.Get("Oracle/StillRunningNoSession");
        }

        return identity.Serial is { } serial && OracleDbmsDebugStatements.KillSession(identity) is { } kill
            ? OracleStrings.Format("Oracle/StillRunningWithKill", identity.Sid, serial, kill)
            : OracleStrings.Format("Oracle/StillRunningSid", identity.Sid);
    }

    public static RoutineDebugException Ambiguous(OracleDebugAmbiguity ambiguity, string subprogram) => ambiguity.Kind switch
    {
        OracleDebugAmbiguityKind.NeedsValue => new RoutineDebugException(
            ambiguity.Parameters.Count == 1
                ? OracleStrings.Format("Oracle/GiveParameterValue", ambiguity.Parameters[0], subprogram)
                : OracleStrings.Format("Oracle/GiveParameterValues", string.Join(", ", ambiguity.Parameters), subprogram),
            OracleStrings.Get("Oracle/OverloadDefaultUnreadable")),
        _ => new RoutineDebugException(
            OracleStrings.Format("Oracle/AmbiguousOverload", subprogram),
            OracleStrings.Get("Oracle/DebugFromCallerOverload")),
    };

    public static RoutineDebugException Argument(OracleDebugArgumentException error) => error.Declarable
        ? new RoutineDebugException(OracleStrings.Format("Oracle/TextToType", error.TypeName, error.Name), OracleStrings.Get("Oracle/TextToTypeDetail"))
        : new RoutineDebugException(OracleStrings.Format("Oracle/CannotPassType", error.TypeName, error.Name), OracleStrings.Get("Oracle/CannotPassTypeDetail"));

    /// <summary>A start failure in the user's terms: ORA-01031 from INITIALIZE is the missing DEBUG CONNECT SESSION.</summary>
    public static Exception StartFailure(Exception error) => error switch
    {
        RoutineDebugException or OperationCanceledException => error,
        OracleDebugServerException server when OracleDebugStatements.ErrorCodes(server.Message) is [1031, ..] =>
            new RoutineDebugException(OracleStrings.Get("Oracle/NeedsDebugConnectSession"), server.Message, server),
        OracleDebugServerException server => new RoutineDebugException(OracleStrings.Get("Oracle/CouldNotStart"), server.Message, server),
        _ => Step(error),
    };

    /// <summary>A failure during a step or a read, in the user's terms.</summary>
    public static Exception Step(Exception error) => error switch
    {
        RoutineDebugException or OperationCanceledException => error,
        OracleDebugEndedException => new RoutineDebugException(Ended, (string?)null),
        FormatException => new RoutineDebugException(Unreadable, (string?)null, error),
        OracleDebugServerException server => new RoutineDebugException(OracleStrings.Get("Oracle/CouldNotFinishStep"), server.Message, server),
        _ => new RoutineDebugException(OracleStrings.Get("Oracle/CouldNotFinishStep"), error.Message, error),
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
