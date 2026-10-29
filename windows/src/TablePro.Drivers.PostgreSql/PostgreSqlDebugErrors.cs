using TablePro.Core.Drivers;
using TablePro.Drivers.PostgreSql.Localization;

namespace TablePro.Drivers.PostgreSql;

/// <summary>Everything the PL/pgSQL debugger says when it cannot go on, each with what to do about it where there is something.</summary>
internal static class PostgreSqlDebugErrors
{
    public static RoutineDebugException ExtensionMissing(string database) =>
        new(PostgreSqlStrings.Format("PostgreSql/ExtensionMissing", database), PostgreSqlStrings.Get("PostgreSql/ExtensionMissingDetail"));

    public static RoutineDebugException ServerPackageMissing() =>
        new(PostgreSqlStrings.Get("PostgreSql/ServerPackageMissing"), PostgreSqlStrings.Get("PostgreSql/ServerPackageMissingDetail"));

    public static RoutineDebugException NotOwner(string routine) => new(PostgreSqlStrings.Format("PostgreSql/NotOwner", routine), (string?)null);

    public static RoutineDebugException SharedMemoryUnavailable() =>
        new(PostgreSqlStrings.Get("PostgreSql/SharedMemoryUnavailable"), PostgreSqlStrings.Get("PostgreSql/SharedMemoryUnavailableDetail"));

    public static RoutineDebugException RoutineNotFound(string routine) => new(PostgreSqlStrings.Format("PostgreSql/RoutineNotFound", routine), (string?)null);

    public static RoutineDebugException NotDebuggable() => new(PostgreSqlStrings.Get("PostgreSql/NotDebuggable"), (string?)null);

    public static RoutineDebugException PseudoTypeParameter() => new(PostgreSqlStrings.Get("PostgreSql/PseudoTypeParameter"), (string?)null);

    public static RoutineDebugException HidesDebuggerNotice(string value) =>
        new(PostgreSqlStrings.Format("PostgreSql/HidesDebuggerNotice", value), PostgreSqlStrings.Get("PostgreSql/HidesDebuggerNoticeDetail"));

    public static RoutineDebugException LimitsTransactionTime(string value) =>
        new(PostgreSqlStrings.Format("PostgreSql/LimitsTransactionTime", value), PostgreSqlStrings.Get("PostgreSql/LimitsTransactionTimeDetail"));

    public static RoutineDebugException TargetAbandoned(int? process, int? port) =>
        new(PostgreSqlDebugProtocol.AbandonedMessage, PostgreSqlDebugProtocol.AbandonedDetail(process, port));

    public static RoutineDebugException Unavailable() => new(PostgreSqlStrings.Get("PostgreSql/Unavailable"), (string?)null);

    public static RoutineDebugException NotPaused() => new(PostgreSqlStrings.Get("PostgreSql/NotPaused"), (string?)null);

    public static RoutineDebugException UnsupportedCommand() => new(PostgreSqlStrings.Get("PostgreSql/CannotStepOut"), (string?)null);

    public static RoutineDebugException NoDefault(string parameter) => new(PostgreSqlStrings.Format("PostgreSql/NoDefault", parameter), (string?)null);

    public static RoutineDebugException DefaultNotReadable(string parameter) =>
        new(PostgreSqlStrings.Format("PostgreSql/DefaultNotReadable", parameter), (string?)null);

    public static RoutineDebugException NoOverloads(string routine) =>
        new(PostgreSqlStrings.Format("PostgreSql/NoOverloads", routine), PostgreSqlStrings.Get("PostgreSql/NoOverloadsDetail"));
}
