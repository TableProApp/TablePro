using System.Globalization;
using System.Text;
using TablePro.Core.Drivers;
using TablePro.Core.Results;
using TablePro.Core.Schema;
using TablePro.Core.Sql;

namespace TablePro.Drivers.PostgreSql;

/// <summary>The routine's call as the target sends it: SQL with <c>$n</c> placeholders and their text values, null for NULL.</summary>
internal sealed record PostgreSqlDebugCall(string Sql, IReadOnlyList<string?> Parameters);

internal enum PostgreSqlDebugProxyFailure
{
    TargetEnded,

    // A signal reached the proxy while it waited: the target is still attached to it and its reply is unread.
    Interrupted,
    Broken,
}

/// <summary>How to end a target whose start was cancelled.</summary>
internal enum PostgreSqlDebugStartCancellation
{
    // The call has not reached the routine: a cancel on the target ends it.
    CancelCall,

    // The target waits in accept() and ignores a cancel: only an attach and pldbg_abort_target end it.
    AttachAndAbort,
    Nothing,
}

internal enum PostgreSqlDebugStartStep
{
    Attach,
    AttachAndAbort,
    Cancelled,
    EndedBeforeEntry,
}

/// <summary>The routine the debugger runs, read in one catalog query (<see cref="PostgreSqlDebugProtocol.RoutineQuery"/>).</summary>
internal sealed class PostgreSqlDebugRoutine
{
    /// <summary>Reads the columns of <see cref="PostgreSqlDebugProtocol.RoutineQuery"/>, in order, all as text.</summary>
    public PostgreSqlDebugRoutine(IReadOnlyList<string?> row, string identity)
    {
        string? Text(int index) => index < row.Count ? row[index] : null;
        bool Flag(int index) => PostgreSqlDebugProtocol.IsTrue(Text(index));

        Identity = identity;
        Database = Text(0) ?? string.Empty;
        ExtensionSchema = Text(1);
        ExtensionAvailable = Flag(2);
        Exists = Flag(3);
        MayDebug = Flag(4);
        Kind = Text(5);
        Volatility = Text(6);
        Language = Text(7);
        Schema = Text(8) ?? string.Empty;
        Name = Text(9) ?? string.Empty;
        IdentityArguments = Text(10) ?? string.Empty;
        ReturnsRecordType = Flag(11);
        ReturnsTrigger = Flag(12);
        Parameters = PostgreSqlDebugProtocol.Parameters(
            PostgreSqlTextArray.Values(Text(13)),
            PostgreSqlTextArray.Elements(Text(14)),
            PostgreSqlTextArray.Values(Text(15)),
            int.TryParse(Text(16), NumberStyles.Integer, CultureInfo.InvariantCulture, out var defaults) ? defaults : 0);
        TakesPseudoType = Flag(17);
        Configuration = PostgreSqlTextArray.Values(Text(18));
        ArgumentCastTypes = PostgreSqlTextArray.Values(Text(19));
        DefaultExpressions = PostgreSqlTextArray.Elements(Text(20));
    }

    public string Identity { get; }

    public string Database { get; }

    public string? ExtensionSchema { get; }

    public bool ExtensionAvailable { get; }

    public bool Exists { get; }

    public bool MayDebug { get; }

    public string? Kind { get; }

    public string? Volatility { get; }

    public string? Language { get; }

    public string Schema { get; }

    public string Name { get; }

    public string IdentityArguments { get; }

    public bool ReturnsRecordType { get; }

    public bool ReturnsTrigger { get; }

    public IReadOnlyList<DebugParameter> Parameters { get; }

    public bool TakesPseudoType { get; }

    public IReadOnlyList<string> Configuration { get; }

    /// <summary>
    /// Each argument's type as its quoted, schema-qualified pg_type name, parallel to <see cref="Parameters"/>. It names
    /// exactly the declared type and no length: format_type's character and bit mean character(1) and bit(1) and cut the
    /// value, and bpchar or varbit can pick another overload than the one being debugged.
    /// </summary>
    public IReadOnlyList<string> ArgumentCastTypes { get; }

    /// <summary>Each argument's default expression from pg_get_function_arg_default, null where it has none.</summary>
    public IReadOnlyList<string?> DefaultExpressions { get; }

    public bool IsProcedure => Kind == "p";

    public string DisplayName => $"{Name}({IdentityArguments})";

    public bool ReturnsBareRecord => ReturnsRecordType && !Parameters.Any(p => p.Mode is DebugParameterMode.Output or DebugParameterMode.InputOutput);

    public DebugEntryPoint EntryPoint => new(Identity, DisplayName, Parameters);

    public string RunNote => IsProcedure
        ? "Changes the procedure makes are committed when it commits or finishes. Stop rolls back what it hasn't committed."
        : "Changes the routine makes are committed when it finishes. Stop rolls them back.";

    /// <summary>
    /// The schema pldbgapi lives in, or why this routine cannot be debugged. It never asks about
    /// shared_preload_libraries: a non-superuser cannot read it, and direct debugging works without it.
    /// </summary>
    public string DebuggerSchema()
    {
        if (Language != "plpgsql" || Kind is not ("f" or "p") || ReturnsTrigger)
        {
            throw PostgreSqlDebugErrors.NotDebuggable();
        }

        if (TakesPseudoType)
        {
            throw PostgreSqlDebugErrors.PseudoTypeParameter();
        }

        if (PostgreSqlDebugProtocol.BlockingSetting(Configuration) is { } blocking)
        {
            throw blocking;
        }

        if (string.IsNullOrEmpty(ExtensionSchema))
        {
            throw ExtensionAvailable ? PostgreSqlDebugErrors.ExtensionMissing(Database) : PostgreSqlDebugErrors.ServerPackageMissing();
        }

        return MayDebug ? ExtensionSchema : throw PostgreSqlDebugErrors.NotOwner(DisplayName);
    }
}

/// <summary>
/// The SQL the PL/pgSQL debugger runs and how its replies read. pldebugger's direct debugging needs two sessions: the
/// target runs the routine and blocks for the whole run, and the proxy drives it through the pldbgapi functions.
/// </summary>
internal static class PostgreSqlDebugProtocol
{
    public static readonly IReadOnlySet<DebugCommand> SupportedCommands = new HashSet<DebugCommand> { DebugCommand.Continue, DebugCommand.StepOver, DebugCommand.StepInto };

    public const string StoppedMessage = "The routine was stopped, and its uncommitted changes were rolled back.";

    // A cancel reaching the proxy does this, and so does a server transaction_timeout on PostgreSQL 17 once a wait
    // outlasts it, even with the session's own set to 0.
    public const string InterruptedMessage =
        "The debugger's session was interrupted while it waited, so the routine was stopped and its uncommitted changes were rolled back. "
        + "A cancel or the server's transaction_timeout can cause this.";

    public const string AbandonedMessage = "The routine couldn't be stopped on the server.";

    private const string BreakNoticePrefix = "PLDBGBREAK:";
    private const string TargetEndedState = "08006";
    private const string QueryCanceledState = "57014";

    private static readonly HashSet<string> TriggerReturnTypes = new(StringComparer.Ordinal) { "trigger", "event_trigger" };

    private static readonly HashSet<string> NoticeHidingLevels = new(StringComparer.Ordinal) { "warning", "error", "fatal", "panic" };

    // A bound text argument stays unknown for a polymorphic parameter, and text cannot become a bare record, so a
    // routine taking one of these cannot be called by the debugger.
    private static readonly HashSet<string> PseudoArgumentTypes = new(StringComparer.Ordinal)
    {
        "\"any\"", "anyelement", "anyarray", "anynonarray", "anyenum", "anyrange", "anymultirange",
        "anycompatible", "anycompatiblearray", "anycompatiblenonarray", "anycompatiblerange",
        "anycompatiblemultirange", "record", "record[]",
    };

    // Named, never cast: event_trigger arrived in 9.3, and a cast to a type the server lacks fails the whole query.
    private const string ReturnsTriggerTest = """
        EXISTS (
            SELECT 1 FROM pg_catalog.pg_type rt
            JOIN pg_catalog.pg_namespace rn ON rn.oid = rt.typnamespace
            WHERE rt.oid = p.prorettype AND rn.nspname = 'pg_catalog' AND rt.typname IN ('trigger', 'event_trigger')
        )
        """;

    // proargtypes holds the arguments a call passes; a pseudo-type there (anyelement, record) cannot be bound.
    private const string PseudoTypeArgumentTest = """
        EXISTS (
            SELECT 1 FROM pg_catalog.unnest(p.proargtypes::pg_catalog.oid[]) AS a(t)
            JOIN pg_catalog.pg_type ty ON ty.oid = a.t
            WHERE ty.typtype = 'p'
        )
        """;

    public static bool IsTrue(string? text) => text is "t" or "true" or "TRUE" or "True" or "1" or "y" or "yes" or "on";

    public static bool HasProcedureKind(int serverVersion) => serverVersion >= 110_000;

    /// <summary>
    /// Each would end a target paused at a breakpoint, or the proxy while it waits for one. A paused target is active and
    /// the proxy idle outside a transaction, so idle_in_transaction_session_timeout never applies.
    /// </summary>
    public static IReadOnlyList<string> SessionSettings(int serverVersion, bool isTarget)
    {
        // Startup commands can leave a transaction open; the routine's changes must neither join it nor be committed by
        // it. First, since a rollback would undo the settings.
        var statements = new List<string> { "ROLLBACK", "SET statement_timeout = 0" };
        if (serverVersion >= 140_000)
        {
            statements.Add("SET idle_session_timeout = 0");
        }

        if (serverVersion >= 170_000)
        {
            statements.Add("SET transaction_timeout = 0");
        }

        // The target announces the port it waits on as a NOTICE, which a stricter level never sends.
        if (isTarget)
        {
            statements.Add("SET client_min_messages = notice");
        }

        return statements;
    }

    /// <summary>Every identity, the entry point's and each unit's, is the routine's oid.</summary>
    public static uint? Oid(string identity) =>
        uint.TryParse(identity, NumberStyles.None, CultureInfo.InvariantCulture, out var oid) ? oid : null;

    /// <summary>One row describing the routine; arrays come back as text, as libpq would send them.</summary>
    public static string RoutineQuery(uint oid, int serverVersion)
    {
        var kindColumn = HasProcedureKind(serverVersion)
            ? "p.prokind"
            : "CASE WHEN p.proisagg THEN 'a' WHEN p.proiswindow THEN 'w' ELSE 'f' END";
        const string ArgumentTypes = "COALESCE(p.proallargtypes, p.proargtypes::pg_catalog.oid[])";

        // pg_get_function_arg_default (9.4) counts arguments from 1; proargtypes as an array starts at 0.
        var defaultsColumn = serverVersion >= 90_400
            ? $"""
                ARRAY(
                    SELECT pg_catalog.pg_get_function_arg_default(
                        p.oid,
                        (s.i - pg_catalog.array_lower({ArgumentTypes}, 1) + 1)::pg_catalog.int4
                    )
                    FROM pg_catalog.generate_subscripts({ArgumentTypes}, 1) AS s(i)
                    ORDER BY s.i
                )::pg_catalog.text
                """
            : "NULL::pg_catalog.text";
        return $"""
            SELECT
                pg_catalog.current_database()::pg_catalog.text,
                (SELECT en.nspname::pg_catalog.text FROM pg_catalog.pg_extension e
                    JOIN pg_catalog.pg_namespace en ON en.oid = e.extnamespace
                    WHERE e.extname = 'pldbgapi'),
                EXISTS (SELECT 1 FROM pg_catalog.pg_available_extensions a WHERE a.name = 'pldbgapi'),
                p.oid IS NOT NULL,
                COALESCE(p.proowner = r.oid OR r.rolsuper, false),
                ({kindColumn})::pg_catalog.text,
                p.provolatile::pg_catalog.text,
                l.lanname::pg_catalog.text,
                n.nspname::pg_catalog.text,
                p.proname::pg_catalog.text,
                pg_catalog.pg_get_function_identity_arguments(p.oid),
                p.prorettype = 'pg_catalog.record'::pg_catalog.regtype,
                {ReturnsTriggerTest},
                ARRAY(
                    SELECT pg_catalog.format_type(({ArgumentTypes})[s.i], NULL)
                    FROM pg_catalog.generate_subscripts({ArgumentTypes}, 1) AS s(i)
                    ORDER BY s.i
                )::pg_catalog.text,
                p.proargnames::pg_catalog.text,
                p.proargmodes::pg_catalog.text[]::pg_catalog.text,
                p.pronargdefaults::pg_catalog.text,
                {PseudoTypeArgumentTest},
                p.proconfig::pg_catalog.text,
                ARRAY(
                    SELECT '"' || pg_catalog.replace(tn.nspname, '"', '""') || '"."'
                        || pg_catalog.replace(ty.typname, '"', '""') || '"'
                    FROM pg_catalog.generate_subscripts({ArgumentTypes}, 1) AS s(i)
                    JOIN pg_catalog.pg_type ty ON ty.oid = ({ArgumentTypes})[s.i]
                    JOIN pg_catalog.pg_namespace tn ON tn.oid = ty.typnamespace
                    ORDER BY s.i
                )::pg_catalog.text,
                {defaultsColumn}
            FROM (SELECT 1) AS one
            LEFT JOIN pg_catalog.pg_proc p ON p.oid = {OidLiteral(oid)}
            LEFT JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
            LEFT JOIN pg_catalog.pg_language l ON l.oid = p.prolang
            LEFT JOIN pg_catalog.pg_roles r ON r.rolname = CURRENT_USER
            """;
    }

    /// <summary>
    /// The PL/pgSQL functions and procedures of schema <c>$1</c> that can be debugged; with <paramref name="byName"/>,
    /// only the overloads named <c>$2</c>, which is how a sidebar entry, one per name, finds its oids.
    /// </summary>
    public static string TargetListQuery(int serverVersion, bool byName)
    {
        var hasProcedureKind = HasProcedureKind(serverVersion);
        var kindColumn = hasProcedureKind ? "p.prokind::pg_catalog.text" : "'f'";
        var kindFilter = hasProcedureKind ? "p.prokind IN ('f', 'p')" : "NOT p.proisagg AND NOT p.proiswindow";
        var nameFilter = byName ? "AND p.proname = $2" : string.Empty;
        return $"""
            SELECT
                p.oid::pg_catalog.text,
                p.proname::pg_catalog.text,
                n.nspname::pg_catalog.text,
                '(' || pg_catalog.pg_get_function_identity_arguments(p.oid) || ')',
                {kindColumn}
            FROM pg_catalog.pg_proc p
            JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
            JOIN pg_catalog.pg_language l ON l.oid = p.prolang
            WHERE n.nspname = $1 {nameFilter}
                AND l.lanname = 'plpgsql'
                AND {kindFilter}
                AND NOT {ReturnsTriggerTest}
                AND NOT {PseudoTypeArgumentTest}
                AND NOT EXISTS (
                    SELECT 1 FROM pg_catalog.pg_depend d
                    WHERE d.classid = 'pg_catalog.pg_proc'::pg_catalog.regclass AND d.objid = p.oid AND d.deptype = 'e'
                )
            ORDER BY p.proname, 4
            """;
    }

    // The owner may signal and see its own backends, so no superuser or pg_signal_backend is needed.
    public static string CancelBackendStatement(int process) =>
        string.Create(CultureInfo.InvariantCulture, $"SELECT pg_catalog.pg_cancel_backend({process})");

    public static string BackendCountStatement(int process) =>
        string.Create(CultureInfo.InvariantCulture, $"SELECT pg_catalog.count(*)::pg_catalog.text FROM pg_catalog.pg_stat_activity WHERE pid = {process}");

    public static string RoutineSourceStatement(uint oid) => $"SELECT p.prosrc FROM pg_catalog.pg_proc p WHERE p.oid = {OidLiteral(oid)}";

    public static string OidDebugStatement(string extensionSchema, uint oid) => $"SELECT {Function("pldbg_oid_debug", extensionSchema)}({OidLiteral(oid)})";

    /// <summary>The argument is the target's backend number from its PLDBGBREAK notice, not a TCP port.</summary>
    public static string AttachStatement(string extensionSchema, int port) =>
        string.Create(CultureInfo.InvariantCulture, $"SELECT {Function("pldbg_attach_to_port", extensionSchema)}({port})::pg_catalog.text");

    public static string WaitStatement(string extensionSchema, int session) =>
        BreakpointRead("pldbg_wait_for_breakpoint", extensionSchema, session.ToString(CultureInfo.InvariantCulture));

    /// <summary>Null for Step Out, which pldbgapi has no call for.</summary>
    public static string? StepStatement(DebugCommand command, string extensionSchema, int session)
    {
        var name = command switch
        {
            DebugCommand.Continue => "pldbg_continue",
            DebugCommand.StepOver => "pldbg_step_over",
            DebugCommand.StepInto => "pldbg_step_into",
            _ => null,
        };
        return name is null ? null : BreakpointRead(name, extensionSchema, session.ToString(CultureInfo.InvariantCulture));
    }

    public static string SelectFrameStatement(string extensionSchema, int session, int level) =>
        BreakpointRead("pldbg_select_frame", extensionSchema, string.Create(CultureInfo.InvariantCulture, $"{session}, {level}"));

    public static string SourceStatement(string extensionSchema, int session, uint oid) =>
        string.Create(CultureInfo.InvariantCulture, $"SELECT {Function("pldbg_get_source", extensionSchema)}({session}, {OidLiteral(oid)})");

    public static string StackStatement(string extensionSchema, int session) =>
        string.Create(
            CultureInfo.InvariantCulture,
            $"SELECT level::pg_catalog.text, targetname, func::pg_catalog.text, linenumber::pg_catalog.text, args FROM {Function("pldbg_get_stack", extensionSchema)}({session})");

    public static string VariablesStatement(string extensionSchema, int session) =>
        string.Create(
            CultureInfo.InvariantCulture,
            $"SELECT name, varclass::pg_catalog.text, linenumber::pg_catalog.text, isunique::pg_catalog.text, isconst::pg_catalog.text, isnotnull::pg_catalog.text, pg_catalog.format_type(dtype, NULL), value FROM {Function("pldbg_get_variables", extensionSchema)}({session})");

    public static string SetBreakpointStatement(string extensionSchema, int session, uint oid, int line) =>
        string.Create(CultureInfo.InvariantCulture, $"SELECT {Function("pldbg_set_breakpoint", extensionSchema)}({session}, {OidLiteral(oid)}, {line})::pg_catalog.text");

    public static string DropBreakpointStatement(string extensionSchema, int session, uint oid, int line) =>
        string.Create(CultureInfo.InvariantCulture, $"SELECT {Function("pldbg_drop_breakpoint", extensionSchema)}({session}, {OidLiteral(oid)}, {line})::pg_catalog.text");

    public static string AbortStatement(string extensionSchema, int session) =>
        string.Create(CultureInfo.InvariantCulture, $"SELECT * FROM {Function("pldbg_abort_target", extensionSchema)}({session})");

    public static string OidLiteral(uint oid) => string.Create(CultureInfo.InvariantCulture, $"'{oid}'::pg_catalog.oid");

    private static string BreakpointRead(string name, string extensionSchema, string arguments) =>
        $"SELECT func::pg_catalog.text, linenumber::pg_catalog.text, targetname FROM {Function(name, extensionSchema)}({arguments})";

    // pldbgapi is relocatable, so every call names the schema it was created in.
    private static string Function(string name, string extensionSchema) => $"{PostgreSqlDialect.Instance.QuoteIdentifier(extensionSchema)}.{name}";

    public static int? DebuggerPort(string notice)
    {
        var trimmed = notice.Trim();
        return trimmed.StartsWith(BreakNoticePrefix, StringComparison.Ordinal)
            && int.TryParse(trimmed.AsSpan(BreakNoticePrefix.Length), NumberStyles.Integer, CultureInfo.InvariantCulture, out var port)
                ? port
                : null;
    }

    /// <summary>
    /// The stop pldebugger reports is one past the statement's line (plpgsql_debugger.c sends lineno + 1); stack frames and
    /// breakpoints use the line itself. Null when the reply holds no stop, which means the target left the debugger.
    /// </summary>
    public static DebugLocation? Location(IReadOnlyList<string?>? row)
    {
        if (row is null || Cell(row, 0) is not { Length: > 0 } unit || Number(Cell(row, 1)) is not { } reported)
        {
            return null;
        }

        return new DebugLocation(new DebugUnit(unit, Cell(row, 2) ?? unit), Math.Max(reported - 1, 1));
    }

    public static DebugFrame? Frame(IReadOnlyList<string?> row)
    {
        if (Number(Cell(row, 0)) is not { } level)
        {
            return null;
        }

        DebugLocation? location = null;
        if (Cell(row, 2) is { } unit && Number(Cell(row, 3)) is { } line)
        {
            location = new DebugLocation(new DebugUnit(unit, Cell(row, 1) ?? unit), line);
        }

        return new DebugFrame(level, location, Cell(row, 4));
    }

    public static DebugVariable? Variable(IReadOnlyList<string?> row)
    {
        if (Cell(row, 0) is not { } name)
        {
            return null;
        }

        var value = Cell(row, 7);

        // pldebugger sends SQL NULL as the text NULL, so it cannot be told from the string 'NULL'.
        return new DebugVariable(name, VariableKind(Cell(row, 1)), Cell(row, 6), value == "NULL" ? null : value, IsTrue(Cell(row, 4)));
    }

    public static DebugVariableKind VariableKind(string? code) => code switch
    {
        "A" => DebugVariableKind.Argument,
        "P" => DebugVariableKind.Package,
        _ => DebugVariableKind.Local,
    };

    /// <summary>
    /// A sidebar routine is a name, which may have overloads, so the target carries no oid and the plan lists each
    /// overload as an entry point.
    /// </summary>
    public static RoutineDebugTarget? Target(DatabaseObject routine) => routine.Kind switch
    {
        ObjectKind.Function => new RoutineDebugTarget(string.Empty, routine.Name, routine.Name.Name, "Function"),
        ObjectKind.Procedure => new RoutineDebugTarget(string.Empty, routine.Name, routine.Name.Name, "Procedure"),
        _ => null,
    };

    public static RoutineDebugTarget? Target(IReadOnlyList<string?> row)
    {
        if (Cell(row, 0) is not { } identity || Oid(identity) is null || Cell(row, 1) is not { } name)
        {
            return null;
        }

        return new RoutineDebugTarget(identity, new ObjectName(Cell(row, 2), name), name + Cell(row, 3), Cell(row, 4) == "p" ? "Procedure" : "Function");
    }

    /// <summary>
    /// Whether a signature, pg_get_function_identity_arguments in parentheses, takes a polymorphic, "any" or record
    /// argument. A type is the last word of its argument, so a parameter merely named like a type does not count.
    /// </summary>
    public static bool SignatureTakesPseudoType(string? signature)
    {
        if (signature is null)
        {
            return false;
        }

        var body = signature.Trim();
        if (body.StartsWith('(') && body.EndsWith(')'))
        {
            body = body[1..^1];
        }

        return QuoteAwareSplit(body, ',').Any(argument =>
            QuoteAwareSplit(argument, ' ').LastOrDefault(part => part.Length > 0) is { } type && PseudoArgumentTypes.Contains(type));
    }

    public static bool ReturnsTrigger(string? returnType) => returnType is not null && TriggerReturnTypes.Contains(returnType.ToLowerInvariant());

    private static List<string> QuoteAwareSplit(string text, char separator)
    {
        var parts = new List<string>();
        var start = 0;
        var quoted = false;
        for (var i = 0; i < text.Length; i++)
        {
            if (text[i] == '"')
            {
                quoted = !quoted;
            }
            else if (text[i] == separator && !quoted)
            {
                parts.Add(text[start..i].Trim());
                start = i + 1;
            }
        }

        parts.Add(text[start..].Trim());
        return parts;
    }

    /// <summary>Catalog arrays as parameters: unnamed ones are named by position, and the last inputs carry the defaults.</summary>
    public static IReadOnlyList<DebugParameter> Parameters(IReadOnlyList<string> types, IReadOnlyList<string?> names, IReadOnlyList<string> modes, int defaultCount)
    {
        var resolvedModes = Enumerable.Range(0, types.Count).Select(i => ParameterMode(i < modes.Count ? modes[i] : "i")).ToArray();
        var inputs = Enumerable.Range(0, types.Count).Where(i => resolvedModes[i] != DebugParameterMode.Output).ToArray();
        var defaulted = inputs.TakeLast(Math.Max(defaultCount, 0)).ToHashSet();
        return
        [
            .. Enumerable.Range(0, types.Count).Select(i =>
            {
                var declared = i < names.Count ? names[i] ?? string.Empty : string.Empty;
                return new DebugParameter(
                    declared.Length == 0 ? string.Create(CultureInfo.InvariantCulture, $"${i + 1}") : declared,
                    types[i],
                    resolvedModes[i],
                    defaulted.Contains(i));
            }),
        ];
    }

    public static DebugParameterMode ParameterMode(string code) => code switch
    {
        "o" or "t" => DebugParameterMode.Output,
        "b" => DebugParameterMode.InputOutput,
        "v" => DebugParameterMode.Variadic,
        _ => DebugParameterMode.Input,
    };

    /// <summary>
    /// The call the target sends. Every argument is bound as text and cast to its exact type, and one left at its default
    /// is spelled out with the routine's own default expression: leaving it out would make overloads that differ only in
    /// defaulted parameters ambiguous, although the oid being debugged is known.
    /// </summary>
    public static PostgreSqlDebugCall Call(PostgreSqlDebugRoutine routine, IReadOnlyList<DebugArgument> arguments)
    {
        var values = new Dictionary<string, DebugArgumentValue>(StringComparer.Ordinal);
        foreach (var argument in arguments)
        {
            values[argument.ParameterName] = argument.Value;
        }

        var expressions = new List<string>();
        var bound = new List<string?>();
        for (var index = 0; index < routine.Parameters.Count; index++)
        {
            var parameter = routine.Parameters[index];
            var castType = index < routine.ArgumentCastTypes.Count ? routine.ArgumentCastTypes[index] : parameter.TypeName;
            string expression;
            if (parameter.Mode == DebugParameterMode.Output)
            {
                // CALL takes a placeholder for each OUT parameter; a function call takes none.
                if (!routine.IsProcedure)
                {
                    continue;
                }

                expression = "NULL::" + castType;
            }
            else
            {
                var value = values.GetValueOrDefault(parameter.Name) ?? (parameter.HasDefault ? DebugArgumentValue.Default : DebugArgumentValue.Null);
                switch (value)
                {
                    case DebugArgumentValue.TextValue text:
                        bound.Add(text.Text);
                        expression = string.Create(CultureInfo.InvariantCulture, $"${bound.Count}::{castType}");
                        break;
                    case DebugArgumentValue.DefaultValue:
                        expression = $"({DefaultExpression(parameter, index, routine)})::{castType}";
                        break;
                    default:
                        bound.Add(null);
                        expression = string.Create(CultureInfo.InvariantCulture, $"${bound.Count}::{castType}");
                        break;
                }
            }

            if (parameter.Mode == DebugParameterMode.Variadic)
            {
                expression = "VARIADIC " + expression;
            }

            expressions.Add(expression);
        }

        var name = PostgreSqlDialect.Instance.Qualify(new ObjectName(routine.Schema, routine.Name));
        var list = string.Join(", ", expressions);
        var sql = routine.IsProcedure
            ? $"CALL {name}({list})"

            // SELECT * FROM a function returning a bare record would need a column definition list.
            : routine.ReturnsBareRecord ? $"SELECT {name}({list})" : $"SELECT * FROM {name}({list})";
        return new PostgreSqlDebugCall(sql, bound);
    }

    private static string DefaultExpression(DebugParameter parameter, int index, PostgreSqlDebugRoutine routine)
    {
        if (!parameter.HasDefault)
        {
            throw PostgreSqlDebugErrors.NoDefault(parameter.Name);
        }

        return index < routine.DefaultExpressions.Count && routine.DefaultExpressions[index] is { } expression
            ? expression
            : throw PostgreSqlDebugErrors.DefaultNotReadable(parameter.Name);
    }

    public static PostgreSqlDebugStartCancellation StartCancellation(bool portDelivered, bool callEnded) =>
        portDelivered ? PostgreSqlDebugStartCancellation.AttachAndAbort
        : callEnded ? PostgreSqlDebugStartCancellation.Nothing
        : PostgreSqlDebugStartCancellation.CancelCall;

    public static PostgreSqlDebugStartStep StartStep(int? port, bool isCancelled) => port is null
        ? isCancelled ? PostgreSqlDebugStartStep.Cancelled : PostgreSqlDebugStartStep.EndedBeforeEntry
        : isCancelled ? PostgreSqlDebugStartStep.AttachAndAbort : PostgreSqlDebugStartStep.Attach;

    /// <summary>A start failure in the user's terms where pldebugger's own message has a known cause.</summary>
    public static Exception StartFailure(Exception error, string database, string routineName)
    {
        if (error is not PostgreSqlDebugServerException failure)
        {
            return error;
        }

        if (IsSharedMemoryFailure(failure.SqlState, failure.MessageText))
        {
            return PostgreSqlDebugErrors.SharedMemoryUnavailable();
        }

        if (failure.SqlState == "42883" && failure.MessageText.Contains("pldbg_", StringComparison.Ordinal))
        {
            return PostgreSqlDebugErrors.ExtensionMissing(database);
        }

        if (failure.SqlState == "42501" && failure.MessageText.Contains("must be owner or superuser", StringComparison.Ordinal))
        {
            return PostgreSqlDebugErrors.NotOwner(routineName);
        }

        return new RoutineDebugException(failure.MessageText, failure.Detail, failure);
    }

    // Without the preload, pldebugger takes its slots from spare shared memory (dbgcomm.c) and can run out.
    private static bool IsSharedMemoryFailure(string? sqlState, string message) =>
        message.Contains("out of shared memory", StringComparison.Ordinal)
        || message.Contains("Debugger Connection slots", StringComparison.Ordinal)
        || (sqlState == "53200" && message.Contains("shared memory", StringComparison.Ordinal));

    /// <summary>
    /// pldbgapi raises 08006 in two cases: "debugger connection terminated" when the target left the debugger, finished
    /// or not, and "select() failed waiting for target" when a signal reached the waiting proxy.
    /// </summary>
    public static PostgreSqlDebugProxyFailure ProxyFailure(Exception error) =>
        error is PostgreSqlDebugServerException { SqlState: TargetEndedState } failure
            ? failure.MessageText.Contains("select() failed", StringComparison.Ordinal) ? PostgreSqlDebugProxyFailure.Interrupted : PostgreSqlDebugProxyFailure.TargetEnded
            : PostgreSqlDebugProxyFailure.Broken;

    /// <summary>How the target's call ending reads: its result, the routine's own error, or the stop that ended it.</summary>
    public static DebugStop End(PostgreSqlDebugCallOutcome outcome, bool stopRequested, bool interrupted = false)
    {
        var ownMessage = interrupted ? InterruptedMessage : StoppedMessage;
        if (outcome.Error is null)
        {
            return new DebugStop.Finished(outcome.Result is { Columns.Count: > 0 } result ? result : null);
        }

        if (outcome.Error is OperationCanceledException)
        {
            return new DebugStop.Failed(ownMessage, null);
        }

        if (outcome.Error is PostgreSqlDebugServerException failure)
        {
            return (stopRequested || interrupted) && failure.SqlState == QueryCanceledState
                ? new DebugStop.Failed(ownMessage, failure.Where)
                : new DebugStop.Failed(failure.MessageText, failure.DetailLines);
        }

        return new DebugStop.Failed(outcome.Error.Message, null);
    }

    /// <summary>
    /// A routine's own SET overrides the session's on entry: a stricter client_min_messages hides the PLDBGBREAK notice,
    /// so the start never sees the target, and a transaction_timeout ends a target waiting at a breakpoint.
    /// </summary>
    public static RoutineDebugException? BlockingSetting(IReadOnlyList<string> configuration)
    {
        foreach (var entry in configuration)
        {
            var separator = entry.IndexOf('=', StringComparison.Ordinal);
            if (separator < 0)
            {
                continue;
            }

            var name = entry[..separator].Trim().ToLowerInvariant();
            var value = entry[(separator + 1)..].Trim();
            if (name == "client_min_messages" && NoticeHidingLevels.Contains(value.ToLowerInvariant()))
            {
                return PostgreSqlDebugErrors.HidesDebuggerNotice(value);
            }

            if (name == "transaction_timeout" && !IsZeroDuration(value))
            {
                return PostgreSqlDebugErrors.LimitsTransactionTime(value);
            }
        }

        return null;
    }

    private static bool IsZeroDuration(string value)
    {
        var digits = 0;
        while (digits < value.Length && char.IsAsciiDigit(value[digits]))
        {
            digits++;
        }

        if (digits == 0 || value.AsSpan(0, digits).ContainsAnyExcept('0'))
        {
            return false;
        }

        return value[digits..].ToLowerInvariant() is "" or "us" or "ms" or "s" or "min" or "h" or "d";
    }

    /// <summary>Ended only when the target's call is known to have returned: then its transaction is over and its locks gone.</summary>
    public static DebugStopOutcome StopOutcome(bool callEnded, bool abandoned, int? process, int? port) =>
        callEnded && !abandoned ? DebugStopOutcome.Ended : DebugStopOutcome.Unconfirmed(AbandonedMessage, AbandonedDetail(process, port));

    public static DebugStop AbandonedStop(int? process, int? port) => new DebugStop.Failed(AbandonedMessage, AbandonedDetail(process, port));

    /// <summary>
    /// Names the backend so someone with access can end it: a target waiting for a debugger ignores cancel and terminate,
    /// and only an attach followed by pldbg_abort_target ends it.
    /// </summary>
    public static string AbandonedDetail(int? process, int? port) => (process, port) switch
    {
        ({ } p, { } q) => string.Create(
            CultureInfo.InvariantCulture,
            $"Server process {p} may still be waiting for a debugger and holding its locks. To end it, run SELECT pldbg_attach_to_port({q}) and pass the number it returns to pldbg_abort_target."),
        ({ } p, null) => string.Create(CultureInfo.InvariantCulture, $"Server process {p} may still be running and holding its locks."),
        _ => "Its server session may still be running and holding its locks.",
    };

    private static string? Cell(IReadOnlyList<string?> row, int index) => index < row.Count ? row[index] : null;

    private static int? Number(string? text) =>
        int.TryParse(text, NumberStyles.Integer, CultureInfo.InvariantCulture, out var number) ? number : null;
}

/// <summary>What the target's call came to: the result it returned, or the error it ended with.</summary>
internal sealed record PostgreSqlDebugCallOutcome(ResultSet? Result, Exception? Error)
{
    public static PostgreSqlDebugCallOutcome Cancelled { get; } = new(null, new OperationCanceledException());
}

/// <summary>An error the server sent, kept apart from a failed transport, since only the server's own error proves the call ended there.</summary>
internal sealed class PostgreSqlDebugServerException : Exception
{
    public PostgreSqlDebugServerException()
        : this("00000", "The server reported an error.")
    {
    }

    public PostgreSqlDebugServerException(string message)
        : this("00000", message)
    {
    }

    public PostgreSqlDebugServerException(string message, Exception innerException)
        : base(message, innerException)
    {
        SqlState = "00000";
        MessageText = message;
    }

    public PostgreSqlDebugServerException(string sqlState, string messageText, string? detail = null, string? hint = null, string? where = null, Exception? innerException = null)
        : base(messageText, innerException)
    {
        SqlState = sqlState;
        MessageText = messageText;
        Detail = detail;
        Hint = hint;
        Where = where;
    }

    public string SqlState { get; }

    public string MessageText { get; }

    public string? Detail { get; }

    public string? Hint { get; }

    /// <summary>The CONTEXT lines: where in the routine it failed.</summary>
    public string? Where { get; }

    public string? DetailLines
    {
        get
        {
            var lines = new[] { Detail, Hint, Where }.Where(l => !string.IsNullOrWhiteSpace(l)).ToArray();
            return lines.Length == 0 ? null : string.Join("\n", lines);
        }
    }
}

/// <summary>PostgreSQL's array output, <c>{a,"b c",NULL}</c>, as its elements.</summary>
internal static class PostgreSqlTextArray
{
    public static IReadOnlyList<string?> Elements(string? literal)
    {
        if (string.IsNullOrEmpty(literal) || literal.Length < 2 || literal[0] != '{' || literal[^1] != '}')
        {
            return [];
        }

        var elements = new List<string?>();
        var body = literal.AsSpan(1, literal.Length - 2);
        if (body.IsEmpty)
        {
            return elements;
        }

        var current = new StringBuilder();
        var quoted = false;
        var wasQuoted = false;
        for (var i = 0; i < body.Length; i++)
        {
            var c = body[i];
            if (quoted)
            {
                if (c == '\\' && i + 1 < body.Length)
                {
                    current.Append(body[++i]);
                }
                else if (c == '"')
                {
                    quoted = false;
                }
                else
                {
                    current.Append(c);
                }
            }
            else if (c == '"')
            {
                quoted = true;
                wasQuoted = true;
            }
            else if (c == ',')
            {
                elements.Add(Element(current, wasQuoted));
                current.Clear();
                wasQuoted = false;
            }
            else
            {
                current.Append(c);
            }
        }

        elements.Add(Element(current, wasQuoted));
        return elements;
    }

    /// <summary>The elements with NULL read as empty, keeping every position.</summary>
    public static IReadOnlyList<string> Values(string? literal) => [.. Elements(literal).Select(e => e ?? string.Empty)];

    private static string? Element(StringBuilder text, bool wasQuoted)
    {
        var value = wasQuoted ? text.ToString() : text.ToString().Trim();
        return !wasQuoted && value.Equals("NULL", StringComparison.OrdinalIgnoreCase) ? null : value;
    }
}
