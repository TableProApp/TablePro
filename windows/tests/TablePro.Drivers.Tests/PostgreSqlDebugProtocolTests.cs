using TablePro.Core.Drivers;
using TablePro.Core.Results;
using TablePro.Core.Schema;
using TablePro.Drivers.PostgreSql;

namespace TablePro.Drivers.Tests;

public sealed class PostgreSqlDebugProtocolTests
{
    /// <summary>The columns of RoutineQuery for public.add_tax(p_amount numeric, p_rate numeric DEFAULT 0.1), as a server sends them.</summary>
    internal static string?[] RoutineRow(
        string? extensionSchema = "public",
        bool available = true,
        bool mayDebug = true,
        string kind = "f",
        string language = "plpgsql",
        bool returnsTrigger = false,
        bool pseudo = false,
        string? configuration = null,
        bool returnsRecord = false,
        string types = "{numeric,numeric}",
        string? names = "{p_amount,p_rate}",
        string? modes = null,
        string defaults = "1",
        string casts = "{\"\\\"pg_catalog\\\".\\\"numeric\\\"\",\"\\\"pg_catalog\\\".\\\"numeric\\\"\"}",
        string? defaultExpressions = "{NULL,0.1}") =>
    [
        "shop", extensionSchema, available ? "t" : "f", "t", mayDebug ? "t" : "f", kind, "v", language, "public", "add_tax",
        "p_amount numeric, p_rate numeric", returnsRecord ? "t" : "f", returnsTrigger ? "t" : "f", types, names, modes, defaults,
        pseudo ? "t" : "f", configuration, casts, defaultExpressions,
    ];

    internal static PostgreSqlDebugRoutine Routine(params string?[] row) => new(row.Length == 0 ? RoutineRow() : row, "16384");

    [Fact]
    public void ThePldbgbreakNoticeNamesTheBackendTheProxyAttachesTo()
    {
        Assert.Equal(7, PostgreSqlDebugProtocol.DebuggerPort("PLDBGBREAK:7"));
        Assert.Equal(12, PostgreSqlDebugProtocol.DebuggerPort("  PLDBGBREAK:12\n"));
        Assert.Null(PostgreSqlDebugProtocol.DebuggerPort("total=11"));
        Assert.Null(PostgreSqlDebugProtocol.DebuggerPort("PLDBGBREAK:x"));
    }

    [Fact]
    public void AStopsReportedLineIsOnePastTheSourceLine()
    {
        var location = PostgreSqlDebugProtocol.Location(["16384", "5", "add_tax"])!;

        Assert.Equal(4, location.Line);
        Assert.Equal(new DebugUnit("16384", "add_tax"), location.Unit);
        Assert.Equal(1, PostgreSqlDebugProtocol.Location(["16384", "1", "add_tax"])!.Line);
    }

    [Fact]
    public void AReplyWithoutAStopMeansTheTargetLeftTheDebugger()
    {
        Assert.Null(PostgreSqlDebugProtocol.Location([null, null, null]));
        Assert.Null(PostgreSqlDebugProtocol.Location(null));
        Assert.Null(PostgreSqlDebugProtocol.Location(["", "4", "add_tax"]));
    }

    [Fact]
    public void AStackFramesLineIsTheSourceLineAsIs()
    {
        var frame = PostgreSqlDebugProtocol.Frame(["1", "run", "16390", "9", "p_n=3"])!;

        Assert.Equal(1, frame.Level);
        Assert.Equal(9, frame.Location!.Line);
        Assert.Equal("run", frame.Location.Unit.DisplayName);
        Assert.Equal("p_n=3", frame.Description);
        Assert.Null(PostgreSqlDebugProtocol.Frame(["x"]));
    }

    [Fact]
    public void VariableClassesMapAndTheTextNullReadsAsSqlNull()
    {
        var argument = PostgreSqlDebugProtocol.Variable(["p_amount", "A", "0", "t", "f", "f", "numeric", "10"])!;
        var local = PostgreSqlDebugProtocol.Variable(["l_tax", "L", "4", "t", "t", "f", "numeric", "NULL"])!;

        Assert.Equal(DebugVariableKind.Argument, argument.Kind);
        Assert.Equal("10", argument.Value);
        Assert.Equal(DebugVariableKind.Local, local.Kind);
        Assert.Null(local.Value);
        Assert.True(local.IsConstant);
        Assert.Equal(DebugVariableKind.Package, PostgreSqlDebugProtocol.VariableKind("P"));
    }

    [Fact]
    public void BreakpointsAreSetOnTheSourceLineUnshifted() =>
        Assert.Equal(
            "SELECT \"debug\".pldbg_set_breakpoint(1, '16384'::pg_catalog.oid, 4)::pg_catalog.text",
            PostgreSqlDebugProtocol.SetBreakpointStatement("debug", 1, 16384, 4));

    [Fact]
    public void TheExtensionsSchemaQualifiesEveryPldbgapiCall()
    {
        Assert.Contains("\"my \"\"ext\"\"\".pldbg_wait_for_breakpoint(3)", PostgreSqlDebugProtocol.WaitStatement("my \"ext\"", 3), StringComparison.Ordinal);
        Assert.Contains("\"public\".pldbg_attach_to_port(7)", PostgreSqlDebugProtocol.AttachStatement("public", 7), StringComparison.Ordinal);
        Assert.Contains("\"public\".pldbg_abort_target(1)", PostgreSqlDebugProtocol.AbortStatement("public", 1), StringComparison.Ordinal);
        Assert.Contains("\"public\".pldbg_select_frame(1, 2)", PostgreSqlDebugProtocol.SelectFrameStatement("public", 1, 2), StringComparison.Ordinal);
    }

    [Fact]
    public void StepOutHasNoPldbgapiCall()
    {
        Assert.Null(PostgreSqlDebugProtocol.StepStatement(DebugCommand.StepOut, "public", 1));
        Assert.Contains("pldbg_step_over(1)", PostgreSqlDebugProtocol.StepStatement(DebugCommand.StepOver, "public", 1), StringComparison.Ordinal);
        Assert.Contains("pldbg_step_into(1)", PostgreSqlDebugProtocol.StepStatement(DebugCommand.StepInto, "public", 1), StringComparison.Ordinal);
        Assert.Contains("pldbg_continue(1)", PostgreSqlDebugProtocol.StepStatement(DebugCommand.Continue, "public", 1), StringComparison.Ordinal);
        Assert.DoesNotContain(DebugCommand.StepOut, PostgreSqlDebugProtocol.SupportedCommands);
    }

    [Fact]
    public void AFunctionRunsAsSelectStarFromWithEachArgumentBoundAndCastToItsExactType()
    {
        var call = PostgreSqlDebugProtocol.Call(Routine(), [new DebugArgument("p_amount", DebugArgumentValue.FromText("10")), new DebugArgument("p_rate", DebugArgumentValue.FromText("0.2"))]);

        Assert.Equal("SELECT * FROM \"public\".\"add_tax\"($1::\"pg_catalog\".\"numeric\", $2::\"pg_catalog\".\"numeric\")", call.Sql);
        Assert.Equal(["10", "0.2"], call.Parameters);
    }

    [Fact]
    public void AnArgumentLeftAtItsDefaultIsSpelledOutSoOverloadsStayApart()
    {
        var call = PostgreSqlDebugProtocol.Call(Routine(), [new DebugArgument("p_amount", DebugArgumentValue.FromText("10")), new DebugArgument("p_rate", DebugArgumentValue.Default)]);

        Assert.Equal("SELECT * FROM \"public\".\"add_tax\"($1::\"pg_catalog\".\"numeric\", (0.1)::\"pg_catalog\".\"numeric\")", call.Sql);
        Assert.Equal(["10"], call.Parameters);
    }

    [Fact]
    public void NullIsBoundAsANullParameterNotAsText()
    {
        var call = PostgreSqlDebugProtocol.Call(Routine(), [new DebugArgument("p_amount", DebugArgumentValue.Null)]);

        Assert.Equal([null], call.Parameters);
        Assert.Contains("(0.1)::", call.Sql, StringComparison.Ordinal);
    }

    [Fact]
    public void DefaultOnAParameterWithoutOneOrUnreadableIsRefused()
    {
        var noDefault = Assert.Throws<RoutineDebugException>(() => PostgreSqlDebugProtocol.Call(Routine(), [new DebugArgument("p_amount", DebugArgumentValue.Default)]));
        Assert.Equal("p_amount has no default value.", noDefault.Message);

        var unreadable = Assert.Throws<RoutineDebugException>(() => PostgreSqlDebugProtocol.Call(Routine(RoutineRow(defaultExpressions: null)), [new DebugArgument("p_amount", DebugArgumentValue.FromText("1"))]));
        Assert.Contains("can't show the default value of p_rate", unreadable.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void AProcedureRunsAsCallWithATypedNullForEachOutParameter()
    {
        var routine = Routine(RoutineRow(kind: "p", types: "{integer,numeric}", names: "{p_n,p_total}", modes: "{i,o}", defaults: "0", casts: "{int4,numeric}", defaultExpressions: "{NULL,NULL}"));

        var call = PostgreSqlDebugProtocol.Call(routine, [new DebugArgument("p_n", DebugArgumentValue.FromText("3"))]);

        Assert.Equal("CALL \"public\".\"add_tax\"($1::int4, NULL::numeric)", call.Sql);
        Assert.True(routine.IsProcedure);
        Assert.StartsWith("Changes the procedure makes", routine.RunNote, StringComparison.Ordinal);
    }

    [Fact]
    public void AFunctionWithOutParametersPassesOnlyItsInputsAndABareRecordIsSelectedAsAValue()
    {
        var withOut = Routine(RoutineRow(types: "{integer,numeric}", names: "{p_n,p_total}", modes: "{i,o}", defaults: "0", casts: "{int4,numeric}", returnsRecord: true));
        Assert.Equal("SELECT * FROM \"public\".\"add_tax\"($1::int4)", PostgreSqlDebugProtocol.Call(withOut, [new DebugArgument("p_n", DebugArgumentValue.FromText("1"))]).Sql);

        var bare = Routine(RoutineRow(types: "{integer}", names: "{p_n}", defaults: "0", casts: "{int4}", returnsRecord: true));
        Assert.Equal("SELECT \"public\".\"add_tax\"($1::int4)", PostgreSqlDebugProtocol.Call(bare, [new DebugArgument("p_n", DebugArgumentValue.FromText("1"))]).Sql);
    }

    [Fact]
    public void AVariadicParameterTakesItsArrayWithVariadic()
    {
        var routine = Routine(RoutineRow(types: "{integer[]}", names: "{p_values}", modes: "{v}", defaults: "0", casts: "{_int4}"));

        Assert.Equal("SELECT * FROM \"public\".\"add_tax\"(VARIADIC $1::_int4)", PostgreSqlDebugProtocol.Call(routine, [new DebugArgument("p_values", DebugArgumentValue.FromText("{1,2}"))]).Sql);
    }

    [Fact]
    public void CatalogArraysBecomeParametersWithModesAndTrailingDefaults()
    {
        var parameters = PostgreSqlDebugProtocol.Parameters(["integer", "text", "numeric", "boolean"], ["a", null, "c", "d"], ["i", "b", "o", "i"], 1);

        Assert.Equal(["a", "$2", "c", "d"], parameters.Select(p => p.Name));
        Assert.Equal([DebugParameterMode.Input, DebugParameterMode.InputOutput, DebugParameterMode.Output, DebugParameterMode.Input], parameters.Select(p => p.Mode));
        Assert.Equal([false, false, false, true], parameters.Select(p => p.HasDefault));
    }

    [Fact]
    public void TextArraysReadQuotesEscapesAndNull()
    {
        Assert.Equal(["a", "b c", null, "x\"y", "NULL"], PostgreSqlTextArray.Elements("{a,\"b c\",NULL,\"x\\\"y\",\"NULL\"}"));
        Assert.Equal(["\"pg_catalog\".\"numeric\""], PostgreSqlTextArray.Elements("{\"\\\"pg_catalog\\\".\\\"numeric\\\"\"}"));
        Assert.Empty(PostgreSqlTextArray.Elements("{}"));
        Assert.Empty(PostgreSqlTextArray.Elements(null));
    }

    [Fact]
    public void TheRoutineRowReadsIntoItsParts()
    {
        var routine = Routine();

        Assert.Equal("add_tax(p_amount numeric, p_rate numeric)", routine.DisplayName);
        Assert.Equal(["\"pg_catalog\".\"numeric\"", "\"pg_catalog\".\"numeric\""], routine.ArgumentCastTypes);
        Assert.Equal([null, "0.1"], routine.DefaultExpressions);
        Assert.Equal("public", routine.DebuggerSchema());
        Assert.Equal("16384", routine.EntryPoint.Identity);
    }

    [Fact]
    public void AMissingExtensionTheServerOffersAsksForCreateExtension()
    {
        var error = Assert.Throws<RoutineDebugException>(() => Routine(RoutineRow(extensionSchema: null)).DebuggerSchema());

        Assert.Equal("The PL/pgSQL debugger isn't installed in \"shop\".", error.Message);
        Assert.Equal("Ask a superuser to run CREATE EXTENSION pldbgapi in this database.", error.Detail);
    }

    [Fact]
    public void AServerWithoutThePldebuggerPackageSaysSo() =>
        Assert.Equal("This server has no PL/pgSQL debugger.", Assert.Throws<RoutineDebugException>(() => Routine(RoutineRow(extensionSchema: null, available: false)).DebuggerSchema()).Message);

    [Fact]
    public void OnlyTheOwnerOrASuperuserMayDebug() =>
        Assert.StartsWith("Only the owner of add_tax", Assert.Throws<RoutineDebugException>(() => Routine(RoutineRow(mayDebug: false)).DebuggerSchema()).Message, StringComparison.Ordinal);

    [Fact]
    public void ATriggerFunctionOrAnotherLanguageOrAPseudoTypeCannotBeDebugged()
    {
        Assert.Throws<RoutineDebugException>(() => Routine(RoutineRow(returnsTrigger: true)).DebuggerSchema());
        Assert.Throws<RoutineDebugException>(() => Routine(RoutineRow(language: "sql")).DebuggerSchema());
        Assert.Throws<RoutineDebugException>(() => Routine(RoutineRow(kind: "a")).DebuggerSchema());
        Assert.Equal(
            "Routines with polymorphic or record parameters can't be debugged.",
            Assert.Throws<RoutineDebugException>(() => Routine(RoutineRow(pseudo: true)).DebuggerSchema()).Message);
    }

    [Theory]
    [InlineData("{client_min_messages=warning}", "client_min_messages to warning")]
    [InlineData("{transaction_timeout=5s}", "transaction_timeout to 5s")]
    public void ARoutineWhoseOwnSettingsWouldStopTheDebuggerIsRefused(string configuration, string expected) =>
        Assert.Contains(expected, Assert.Throws<RoutineDebugException>(() => Routine(RoutineRow(configuration: configuration)).DebuggerSchema()).Message, StringComparison.Ordinal);

    [Theory]
    [InlineData("transaction_timeout=0")]
    [InlineData("transaction_timeout=0ms")]
    [InlineData("client_min_messages=notice")]
    [InlineData("search_path=public")]
    public void HarmlessSettingsAreAllowed(string entry) => Assert.Null(PostgreSqlDebugProtocol.BlockingSetting([entry]));

    [Theory]
    [InlineData("(IN a integer, b anyelement)", true)]
    [InlineData("(r record)", true)]
    [InlineData("(x \"any\")", true)]
    [InlineData("(anyelement integer)", false)]
    [InlineData("(\"weird, name\" text)", false)]
    [InlineData("()", false)]
    [InlineData(null, false)]
    public void PseudoTypesAreFoundInASignatureButNotInAParameterName(string? signature, bool expected) =>
        Assert.Equal(expected, PostgreSqlDebugProtocol.SignatureTakesPseudoType(signature));

    [Fact]
    public void ASidebarFunctionOrProcedureIsATargetFoundByName()
    {
        var target = PostgreSqlDebugProtocol.Target(new DatabaseObject(new ObjectName("public", "add_tax"), ObjectKind.Function))!;

        Assert.Equal(string.Empty, target.Identity);
        Assert.Equal("Function", target.KindDisplayName);
        Assert.Equal("Procedure", PostgreSqlDebugProtocol.Target(new DatabaseObject(new ObjectName("public", "run"), ObjectKind.Procedure))!.KindDisplayName);
        Assert.Null(PostgreSqlDebugProtocol.Target(new DatabaseObject(new ObjectName("public", "orders"), ObjectKind.Table)));
    }

    [Theory]
    [InlineData(Core.Connections.DatabaseEngine.PostgreSql, true)]
    [InlineData(Core.Connections.DatabaseEngine.CockroachDb, false)]
    [InlineData(Core.Connections.DatabaseEngine.Redshift, false)]
    [InlineData(Core.Connections.DatabaseEngine.PGlite, false)]
    public async Task OnlyPostgreSqlItselfOffersTheDebugger(Core.Connections.DatabaseEngine engine, bool offered)
    {
        await using var session = new PostgreSqlSession(Profiles.Request(engine));

        var target = session.GetDebugTarget(new DatabaseObject(new ObjectName("public", "add_tax"), ObjectKind.Function));

        Assert.Equal(offered, target is not null);
    }

    [Fact]
    public void AListRowIsATargetNamedWithItsArguments()
    {
        var target = PostgreSqlDebugProtocol.Target(["16384", "add_tax", "public", "(p_amount numeric)", "f"])!;

        Assert.Equal("16384", target.Identity);
        Assert.Equal("add_tax(p_amount numeric)", target.DisplayName);
        Assert.Null(PostgreSqlDebugProtocol.Target(["x", "add_tax", "public", "()", "f"]));
    }

    [Fact]
    public void TheCatalogReadsNameTheTriggerTypesRatherThanCastToOne()
    {
        var query = PostgreSqlDebugProtocol.RoutineQuery(16384, 90_200);

        Assert.Contains("rt.typname IN ('trigger', 'event_trigger')", query, StringComparison.Ordinal);
        Assert.DoesNotContain("::pg_catalog.regtype IN", query, StringComparison.Ordinal);
        Assert.Contains("p.proisagg", query, StringComparison.Ordinal);
        Assert.Contains("NULL::pg_catalog.text", query, StringComparison.Ordinal);
        Assert.Contains("p.prokind", PostgreSqlDebugProtocol.RoutineQuery(16384, 170_000), StringComparison.Ordinal);
        Assert.Contains("p.proname = $2", PostgreSqlDebugProtocol.TargetListQuery(170_000, byName: true), StringComparison.Ordinal);
    }

    [Fact]
    public void BothSessionsTurnTheirTimeoutsOffAndTheTargetLetsThePortNoticeThrough()
    {
        Assert.Equal(["ROLLBACK", "SET statement_timeout = 0", "SET idle_session_timeout = 0", "SET transaction_timeout = 0", "SET client_min_messages = notice"], PostgreSqlDebugProtocol.SessionSettings(170_002, isTarget: true));
        Assert.Equal(["ROLLBACK", "SET statement_timeout = 0", "SET idle_session_timeout = 0"], PostgreSqlDebugProtocol.SessionSettings(160_004, isTarget: false));
        Assert.Equal(["ROLLBACK", "SET statement_timeout = 0"], PostgreSqlDebugProtocol.SessionSettings(130_000, isTarget: false));
    }

    [Fact]
    public void ACancelledStartCancelsTheCallBeforeEntryAndAttachesAndAbortsAfter()
    {
        Assert.Equal(PostgreSqlDebugStartCancellation.CancelCall, PostgreSqlDebugProtocol.StartCancellation(portDelivered: false, callEnded: false));
        Assert.Equal(PostgreSqlDebugStartCancellation.AttachAndAbort, PostgreSqlDebugProtocol.StartCancellation(portDelivered: true, callEnded: false));
        Assert.Equal(PostgreSqlDebugStartCancellation.Nothing, PostgreSqlDebugProtocol.StartCancellation(portDelivered: false, callEnded: true));
        Assert.Equal(PostgreSqlDebugStartStep.AttachAndAbort, PostgreSqlDebugProtocol.StartStep(7, isCancelled: true));
        Assert.Equal(PostgreSqlDebugStartStep.Attach, PostgreSqlDebugProtocol.StartStep(7, isCancelled: false));
        Assert.Equal(PostgreSqlDebugStartStep.Cancelled, PostgreSqlDebugProtocol.StartStep(null, isCancelled: true));
        Assert.Equal(PostgreSqlDebugStartStep.EndedBeforeEntry, PostgreSqlDebugProtocol.StartStep(null, isCancelled: false));
    }

    [Fact]
    public void StartErrorsMapToTheirCauses()
    {
        Assert.StartsWith("The PL/pgSQL debugger isn't installed", PostgreSqlDebugProtocol.StartFailure(new PostgreSqlDebugServerException("42883", "function public.pldbg_oid_debug(oid) does not exist"), "shop", "f()").Message, StringComparison.Ordinal);
        Assert.StartsWith("Only the owner of f()", PostgreSqlDebugProtocol.StartFailure(new PostgreSqlDebugServerException("42501", "must be owner or superuser to debug"), "shop", "f()").Message, StringComparison.Ordinal);
        Assert.Equal("The server couldn't start the debugger.", PostgreSqlDebugProtocol.StartFailure(new PostgreSqlDebugServerException("53200", "out of shared memory"), "shop", "f()").Message);
        var other = new InvalidOperationException("boom");
        Assert.Same(other, PostgreSqlDebugProtocol.StartFailure(other, "shop", "f()"));
    }

    [Fact]
    public void TheProxys08006MeansTheTargetLeftUnlessASignalInterruptedTheWait()
    {
        Assert.Equal(PostgreSqlDebugProxyFailure.TargetEnded, PostgreSqlDebugProtocol.ProxyFailure(new PostgreSqlDebugServerException("08006", "debugger connection terminated")));
        Assert.Equal(PostgreSqlDebugProxyFailure.Interrupted, PostgreSqlDebugProtocol.ProxyFailure(new PostgreSqlDebugServerException("08006", "select() failed waiting for target")));
        Assert.Equal(PostgreSqlDebugProxyFailure.Broken, PostgreSqlDebugProtocol.ProxyFailure(new PostgreSqlDebugServerException("XX000", "anything")));
        Assert.Equal(PostgreSqlDebugProxyFailure.Broken, PostgreSqlDebugProtocol.ProxyFailure(new IOException("reset")));
    }

    [Fact]
    public void TheTargetsCancelAfterAStopReadsAsStoppedAndARoutineErrorKeepsItsContext()
    {
        var cancelled = new PostgreSqlDebugCallOutcome(null, new PostgreSqlDebugServerException("57014", "canceling statement due to user request", where: "PL/pgSQL function add_tax line 4"));
        var stopped = Assert.IsType<DebugStop.Failed>(PostgreSqlDebugProtocol.End(cancelled, stopRequested: true));
        Assert.Equal(PostgreSqlDebugProtocol.StoppedMessage, stopped.Message);
        Assert.Equal("PL/pgSQL function add_tax line 4", stopped.Detail);

        var interrupted = Assert.IsType<DebugStop.Failed>(PostgreSqlDebugProtocol.End(cancelled, stopRequested: false, interrupted: true));
        Assert.Equal(PostgreSqlDebugProtocol.InterruptedMessage, interrupted.Message);

        var raised = Assert.IsType<DebugStop.Failed>(PostgreSqlDebugProtocol.End(new PostgreSqlDebugCallOutcome(null, new PostgreSqlDebugServerException("P0001", "rate too high", hint: "Lower it", where: "line 4")), false));
        Assert.Equal("rate too high", raised.Message);
        Assert.Equal("Lower it\nline 4", raised.Detail);

        Assert.Equal(PostgreSqlDebugProtocol.StoppedMessage, Assert.IsType<DebugStop.Failed>(PostgreSqlDebugProtocol.End(PostgreSqlDebugCallOutcome.Cancelled, false)).Message);
    }

    [Fact]
    public void AFinishedRoutineCarriesItsResultOrNoneWithoutColumns()
    {
        var result = new ResultSet([new ResultColumn("add_tax", "numeric", typeof(decimal))], [[11m]]);

        Assert.Same(result, Assert.IsType<DebugStop.Finished>(PostgreSqlDebugProtocol.End(new PostgreSqlDebugCallOutcome(result, null), false)).Result);
        Assert.Null(Assert.IsType<DebugStop.Finished>(PostgreSqlDebugProtocol.End(new PostgreSqlDebugCallOutcome(new ResultSet([], []), null), false)).Result);
    }

    [Fact]
    public void AStopThatCouldNotConfirmTheEndNamesTheProcessAndTheSqlThatEndsIt()
    {
        Assert.True(PostgreSqlDebugProtocol.StopOutcome(callEnded: true, abandoned: false, 4242, 7).Confirmed);
        var outcome = PostgreSqlDebugProtocol.StopOutcome(callEnded: false, abandoned: false, 4242, 7);
        Assert.False(outcome.Confirmed);
        Assert.Contains("Server process 4242", outcome.Detail, StringComparison.Ordinal);
        Assert.Contains("pldbg_attach_to_port(7)", outcome.Detail, StringComparison.Ordinal);
        Assert.Equal("Server process 4242 may still be running and holding its locks.", PostgreSqlDebugProtocol.AbandonedDetail(4242, null));
        Assert.Equal("Its server session may still be running and holding its locks.", PostgreSqlDebugProtocol.AbandonedDetail(null, 7));
    }
}
