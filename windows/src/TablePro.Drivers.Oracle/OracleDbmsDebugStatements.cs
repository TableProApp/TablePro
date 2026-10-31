using System.Globalization;
using TablePro.Drivers.Oracle.Localization;

namespace TablePro.Drivers.Oracle;

internal sealed record OracleDebugSessionIdentity(int Sid, int? Serial, int? Instance = null);

/// <summary>A frame of DBMS_DEBUG's backtrace, oldest first, as PRINT_BACKTRACE numbers them.</summary>
internal sealed record OracleDbmsDebugFrame(string? Owner, string? Name, int? Namespace, int? LibunitType, int? Line, string? EntryPoint)
{
    /// <summary>Null for the anonymous block that called the entry point, which has namespace 0 and no name.</summary>
    public OracleDebugUnit? Unit =>
        Owner is not null && !string.IsNullOrEmpty(Name) && Namespace is { } ns && OracleDebugUnitKinds.FromNamespace(ns, LibunitType ?? -1) is { } kind
            ? new OracleDebugUnit(Owner, Name, kind)
            : null;
}

internal sealed record OracleDbmsDebugEvent(int Status, int? Reason, bool Terminated, int? Line, int? Breakpoint, IReadOnlyList<OracleDbmsDebugFrame> Backtrace)
{
    public bool TimedOut => Status == OracleDbmsDebugStatements.StatusTimeout;

    public bool IsPause => Status == OracleDbmsDebugStatements.StatusSuccess && !Terminated;
}

/// <summary>A variable's value as DBMS_DEBUG gives it: text or NULL, a collection it will not show, or nothing readable.</summary>
internal sealed record OracleDebugValue(string? Text, bool IsCollection = false, bool IsUnavailable = false)
{
    public static readonly OracleDebugValue Collection = new(null, IsCollection: true);

    public static readonly OracleDebugValue Unavailable = new(null, IsUnavailable: true);

    /// <summary>Null is SQL NULL, so a value the debugger cannot read is said in words.</summary>
    public string? Display => IsCollection ? OracleStrings.Get("Oracle/ValueCollection") : IsUnavailable ? OracleStrings.Get("Oracle/ValueNotReadable") : Text;
}

/// <summary>A name GET_VALUE reads, from a frame by its number or from a package by its handle.</summary>
internal sealed record OracleDbmsValueRequest(string Name, int? Frame, OracleDebugUnit? Package);

/// <summary>
/// DBMS_DEBUG's two sessions: the target runs the routine in debug mode, the supervisor drives it. Every supervisor call is
/// one block that answers through <see cref="OracleDebugPayload"/>, because the runtime_info and program_info records
/// cannot be bound.
/// </summary>
internal static class OracleDbmsDebugStatements
{
    public const int BreakpointsOnly = 0;
    public const int NextLine = 32;
    public const int AnyCall = 12;

    // Named backwards in the package (its own comment says so): this one stops in the caller after the return.
    public const int AnyReturn = 512;
    public const int AbortExecution = 8_192;

    public const int StatusSuccess = 0;
    public const int StatusIndexedTable = 18;
    public const int StatusTimeout = 31;
    public const int StatusNullValue = 32;
    public const int StatusNullCollection = 40;

    /// <summary>
    /// How long the target waits for the supervisor at a stop before it aborts itself. The supervisor pings it while the
    /// user reads a pause, so only a supervisor that went away lets it run out.
    /// </summary>
    public const int TargetTimeoutSeconds = 30;

    public const int PingIntervalSeconds = 10;

    /// <summary>How long one supervisor wait lasts before it returns to check for a stop and for the target's call ending.</summary>
    public const int SupervisorTimeoutSeconds = 1;

    private const int AbortOnTimeout = 3;
    private const int InfoFlags = 2 + 4 + 8;

    public static readonly string TargetSetup = string.Create(CultureInfo.InvariantCulture, $"""
        DECLARE
          l_id VARCHAR2(32767);
          l_timeout BINARY_INTEGER;
        BEGIN
          EXECUTE IMMEDIATE 'CALL SYS.DBMS_DEBUG.INITIALIZE(:1) INTO :2' USING :b1, OUT l_id;
          EXECUTE IMMEDIATE 'CALL SYS.DBMS_DEBUG.SET_TIMEOUT_BEHAVIOUR({AbortOnTimeout})';
          EXECUTE IMMEDIATE 'CALL SYS.DBMS_DEBUG.SET_TIMEOUT({TargetTimeoutSeconds}) INTO :1' USING OUT l_timeout;
          EXECUTE IMMEDIATE 'CALL SYS.DBMS_DEBUG.DEBUG_ON()';
        END;
        """);

    /// <summary>
    /// Read before DEBUG_ON, so the target's own PL/SQL does not stop it. DBMS_DEBUG_JDWP's functions answer for any user,
    /// V$SESSION needs SELECT_CATALOG_ROLE, and the SID alone always works.
    /// </summary>
    public static readonly IReadOnlyList<string> SessionIdentityQueries =
    [
        "SELECT TO_CHAR(SYS.DBMS_DEBUG_JDWP.CURRENT_SESSION_ID), TO_CHAR(SYS.DBMS_DEBUG_JDWP.CURRENT_SESSION_SERIAL), SYS_CONTEXT('USERENV', 'INSTANCE') FROM SYS.DUAL",
        "SELECT TO_CHAR(SID), TO_CHAR(SERIAL#), SYS_CONTEXT('USERENV', 'INSTANCE') FROM SYS.V_$SESSION WHERE SID = SYS_CONTEXT('USERENV', 'SID')",
        "SELECT SYS_CONTEXT('USERENV', 'SID'), NULL, SYS_CONTEXT('USERENV', 'INSTANCE') FROM SYS.DUAL",
    ];

    /// <summary>The supervisor runs no code of the user's, so its schema can be its own, which keeps SYS meaning the schema below.</summary>
    public const string OwnSchema = """
        BEGIN
          EXECUTE IMMEDIATE 'ALTER SESSION SET CURRENT_SCHEMA = "' || REPLACE(SYS_CONTEXT('USERENV', 'SESSION_USER'), '"', '""') || '"';
        END;
        """;

    public static readonly string Attach = string.Create(CultureInfo.InvariantCulture, $"""
        DECLARE
          l_timeout BINARY_INTEGER;
        BEGIN
          l_timeout := SYS.DBMS_DEBUG.SET_TIMEOUT({SupervisorTimeoutSeconds});
          SYS.DBMS_DEBUG.ATTACH_SESSION(:b1);
        END;
        """);

    public const string Detach = """
        BEGIN
          SYS.DBMS_DEBUG.DETACH_SESSION;
        END;
        """;

    public const string Ping = """
        BEGIN
          SYS.DBMS_DEBUG.PING;
        EXCEPTION
          WHEN OTHERS THEN NULL;
        END;
        """;

    public static OracleDebugSessionIdentity? SessionIdentity(IReadOnlyList<string?> row)
    {
        int? Number(int index) =>
            index < row.Count && int.TryParse(row[index]?.Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out var value) ? value : null;

        return Number(0) is { } sid ? new OracleDebugSessionIdentity(sid, Number(1), Number(2)) : null;
    }

    /// <summary>Ends a target the supervisor cannot reach between breakpoints. Needs ALTER SYSTEM; ORA-01031 otherwise.</summary>
    public static string? KillSession(OracleDebugSessionIdentity identity)
    {
        if (identity.Serial is not { } serial)
        {
            return null;
        }

        var instance = identity.Instance is { } i ? string.Create(CultureInfo.InvariantCulture, $",@{i}") : string.Empty;
        return string.Create(CultureInfo.InvariantCulture, $"ALTER SYSTEM KILL SESSION '{identity.Sid},{serial}{instance}' IMMEDIATE");
    }

    /// <summary>
    /// Continues with <paramref name="flags"/>, or synchronizes when null. A stop answers the runtime record and the
    /// backtrace in one round trip; a terminated program has no backtrace, and asking for one there raises inside the package.
    /// </summary>
    public static string Resume(int? flags)
    {
        var call = flags is { } f
            ? string.Create(CultureInfo.InvariantCulture, $"SYS.DBMS_DEBUG.CONTINUE(l_info, {f}, {InfoFlags})")
            : string.Create(CultureInfo.InvariantCulture, $"SYS.DBMS_DEBUG.SYNCHRONIZE(l_info, {InfoFlags})");
        return $"""
            DECLARE
              l_info SYS.DBMS_DEBUG.RUNTIME_INFO;
              l_trace SYS.DBMS_DEBUG.BACKTRACE_TABLE;
              l_status BINARY_INTEGER;
            {OracleDebugPayload.Declarations}
            BEGIN
              l_status := {call};
              put(TO_CHAR(l_status));
              put(TO_CHAR(l_info.Reason));
              put(TO_CHAR(l_info.Terminated));
              put(TO_CHAR(l_info.Line#));
              put(TO_CHAR(l_info.Breakpoint));
              IF l_status = 0 AND NVL(l_info.Terminated, 0) = 0 THEN
                SYS.DBMS_DEBUG.PRINT_BACKTRACE(l_trace);
                put(TO_CHAR(l_trace.COUNT));
                FOR i IN 1 .. l_trace.COUNT LOOP
                  put(l_trace(i).Owner);
                  put(l_trace(i).Name);
                  put(TO_CHAR(l_trace(i).Namespace));
                  put(TO_CHAR(l_trace(i).LibunitType));
                  put(TO_CHAR(l_trace(i).Line#));
                  put(l_trace(i).EntrypointName);
                END LOOP;
              ELSE
                put('0');
              END IF;
            {OracleDebugPayload.OpenCursor}
            END;
            """;
    }

    public static string SetBreakpoint(OracleDebugUnit unit, int line) => string.Create(CultureInfo.InvariantCulture, $"""
        DECLARE
          l_program SYS.DBMS_DEBUG.PROGRAM_INFO;
          l_number BINARY_INTEGER;
          l_status BINARY_INTEGER;
        {OracleDebugPayload.Declarations}
        BEGIN
          l_program.Namespace := {unit.Kind.Namespace()};
          l_program.Owner := {OracleDebugUnit.Literal(unit.Owner)};
          l_program.Name := {OracleDebugUnit.Literal(unit.Name)};
          l_program.Line# := {line};
          l_status := SYS.DBMS_DEBUG.SET_BREAKPOINT(l_program, {line}, l_number);
          put(TO_CHAR(l_status));
          put(TO_CHAR(l_number));
        {OracleDebugPayload.OpenCursor}
        END;
        """);

    public static string DeleteBreakpoints(IEnumerable<int> numbers)
    {
        var calls = string.Join('\n', numbers.Select(n => string.Create(CultureInfo.InvariantCulture, $"  l_status := SYS.DBMS_DEBUG.DELETE_BREAKPOINT({n});")));
        return $"""
            DECLARE
              l_status BINARY_INTEGER;
            BEGIN
            {(calls.Length == 0 ? "  NULL;" : calls)}
            END;
            """;
    }

    /// <summary>GET_LINE_MAP answers from any session, before or without ATTACH_SESSION.</summary>
    public static string LineMap(OracleDebugUnit unit) => string.Create(CultureInfo.InvariantCulture, $"""
        DECLARE
          l_program SYS.DBMS_DEBUG.PROGRAM_INFO;
          l_max BINARY_INTEGER;
          l_entries BINARY_INTEGER;
          l_map RAW(32767);
          l_status BINARY_INTEGER;
        {OracleDebugPayload.Declarations}
        BEGIN
          l_program.Namespace := {unit.Kind.Namespace()};
          l_program.Owner := {OracleDebugUnit.Literal(unit.Owner)};
          l_program.Name := {OracleDebugUnit.Literal(unit.Name)};
          l_status := SYS.DBMS_DEBUG.GET_LINE_MAP(l_program, l_max, l_entries, l_map);
          put(TO_CHAR(l_status));
          put(TO_CHAR(l_max));
          put(RAWTOHEX(l_map));
        {OracleDebugPayload.OpenCursor}
        END;
        """);

    /// <summary>A name comes from the unit's source text, so request n's goes in as bind :bn, never as SQL.</summary>
    public static (string Block, IReadOnlyList<string?> Binds) Values(IReadOnlyList<OracleDbmsValueRequest> requests)
    {
        var reads = requests.Select((request, index) =>
        {
            var name = string.Create(CultureInfo.InvariantCulture, $":b{index + 1}");
            if (request.Package is { } package)
            {
                return string.Create(CultureInfo.InvariantCulture, $"""
                      l_handle.Namespace := {package.Kind.Namespace()};
                      l_handle.Owner := {OracleDebugUnit.Literal(package.Owner)};
                      l_handle.Name := {OracleDebugUnit.Literal(package.Name)};
                      l_value := NULL;
                      l_status := SYS.DBMS_DEBUG.GET_VALUE({name}, l_handle, l_value, NULL);
                      put(TO_CHAR(l_status));
                      put(l_value);
                    """);
            }

            return string.Create(CultureInfo.InvariantCulture, $"""
                  l_value := NULL;
                  l_status := SYS.DBMS_DEBUG.GET_VALUE({name}, {request.Frame ?? 0}, l_value, NULL);
                  put(TO_CHAR(l_status));
                  put(l_value);
                """);
        });
        var block = $"""
            DECLARE
              l_handle SYS.DBMS_DEBUG.PROGRAM_INFO;
              l_value VARCHAR2(32767);
              l_status BINARY_INTEGER;
            {OracleDebugPayload.Declarations}
            BEGIN
            {string.Join('\n', reads)}
            {OracleDebugPayload.OpenCursor}
            END;
            """;
        return (block, [.. requests.Select(r => (string?)r.Name)]);
    }

    public static OracleDbmsDebugEvent Event(IReadOnlyList<string?> fields)
    {
        var reader = new OracleDebugPayloadReader(fields);
        var status = reader.Int() ?? -1;
        var reason = reader.Int();
        var terminated = (reader.Int() ?? 0) != 0;
        var line = reader.Int();
        var breakpoint = reader.Int();
        var count = reader.Int() ?? 0;
        var frames = new List<OracleDbmsDebugFrame>();
        for (var i = 0; i < Math.Max(count, 0); i++)
        {
            frames.Add(new OracleDbmsDebugFrame(reader.Next(), reader.Next(), reader.Int(), reader.Int(), reader.Int(), reader.Next()));
        }

        return new OracleDbmsDebugEvent(status, reason, terminated, line, breakpoint, frames);
    }

    public static (int Status, int? Number) BreakpointAnswer(IReadOnlyList<string?> fields)
    {
        var reader = new OracleDebugPayloadReader(fields);
        return (reader.Int() ?? -1, reader.Int());
    }

    public static IReadOnlyList<(int Status, string? Value)> ValueAnswers(IReadOnlyList<string?> fields, int count)
    {
        var reader = new OracleDebugPayloadReader(fields);
        var answers = new List<(int, string?)>();
        for (var i = 0; i < count; i++)
        {
            answers.Add((reader.Int() ?? -1, reader.Next()));
        }

        return answers;
    }

    /// <summary>The value GET_VALUE's status means, or null when the name is not in scope and is to be left out.</summary>
    public static OracleDebugValue? Value(int status, string? text) => status switch
    {
        StatusSuccess => new OracleDebugValue(text),
        StatusNullValue or StatusNullCollection => new OracleDebugValue(null),
        StatusIndexedTable => OracleDebugValue.Collection,
        _ => null,
    };

    /// <summary>The executable lines, or null when the unit has no line map (status other than success).</summary>
    public static IReadOnlyList<int>? ExecutableLines(IReadOnlyList<string?> fields)
    {
        var reader = new OracleDebugPayloadReader(fields);
        if (reader.Int() != StatusSuccess)
        {
            return null;
        }

        var maxLine = reader.Int() ?? 0;
        return ExecutableLines(reader.Next() ?? string.Empty, maxLine);
    }

    /// <summary>Line N is executable when bit N mod 8 of byte N / 8 is set, as the package describes its map.</summary>
    public static IReadOnlyList<int> ExecutableLines(string hex, int maxLine)
    {
        var bytes = new List<byte>();
        for (var i = 0; i + 1 < hex.Length; i += 2)
        {
            if (byte.TryParse(hex.AsSpan(i, 2), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var value))
            {
                bytes.Add(value);
            }
        }

        // The map holds eight lines a byte, so a larger maxLine adds nothing to read.
        var last = Math.Min(Math.Max(maxLine, 0), (bytes.Count * 8) - 1);
        var lines = new List<int>();
        for (var line = 1; line <= last; line++)
        {
            if ((bytes[line / 8] & (1 << (line % 8))) != 0)
            {
                lines.Add(line);
            }
        }

        return lines;
    }
}
