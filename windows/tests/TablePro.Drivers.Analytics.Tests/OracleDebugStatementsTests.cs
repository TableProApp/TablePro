using TablePro.Drivers.Oracle;

namespace TablePro.Drivers.Analytics.Tests;

public sealed class OracleDebugStatementsTests
{
    private static readonly OracleDebugUnit PkgCalc = new("PROBE", "PKG_CALC", OracleDebugUnitKind.PackageBody);

    [Fact]
    public void AUnitsIdentityRoundTripsAndEscapesItsSeparators()
    {
        var unit = new OracleDebugUnit("A/B", "100%", OracleDebugUnitKind.PackageBody);

        Assert.Equal("PACKAGE BODY/A%2FB/100%25", unit.Identity);
        Assert.Equal(unit, OracleDebugUnit.FromIdentity(unit.Identity));
        Assert.Null(OracleDebugUnit.FromIdentity("NOPE/X/Y"));

        var entry = new OracleDebugEntry(unit, "RUN/2", 3);
        Assert.Equal(entry, OracleDebugEntry.FromIdentity(entry.Identity));
        Assert.True(entry.IsPackaged);
    }

    [Fact]
    public void APackageRunsItsBodyAndCompilesOnlyTheBodyForDebug()
    {
        var spec = new OracleDebugUnit("PROBE", "PKG_CALC", OracleDebugUnitKind.Package);

        Assert.Equal(PkgCalc, spec.CodeUnit);
        Assert.Equal("PROBE.PKG_CALC (specification)", spec.DisplayName);
        Assert.Equal("ALTER PACKAGE \"PROBE\".\"PKG_CALC\" COMPILE BODY PLSQL_OPTIMIZE_LEVEL=1 REUSE SETTINGS", spec.Kind.CompileForDebugStatement("PROBE", "PKG_CALC"));
        Assert.Equal("ALTER PROCEDURE \"PROBE\".\"RUN_CALC\" COMPILE PLSQL_OPTIMIZE_LEVEL=1 REUSE SETTINGS", OracleDebugUnitKind.Procedure.CompileForDebugStatement("PROBE", "RUN_CALC"));
    }

    [Theory]
    [InlineData(1, 7, "PROCEDURE")]
    [InlineData(1, 8, "FUNCTION")]
    [InlineData(2, 11, "PACKAGE BODY")]
    [InlineData(3, 0, "TRIGGER")]
    public void BacktraceNamespacesMapToUnitKinds(int ns, int libunit, string expected)
    {
        Assert.Equal(expected, OracleDebugUnitKinds.FromNamespace(ns, libunit)?.TypeName());
        Assert.Null(OracleDebugUnitKinds.FromNamespace(0, 0));
    }

    [Fact]
    public async Task SidebarRoutinesAndPackagesAreTargetsAndOtherObjectsAreNot()
    {
        await using var session = new OracleSession(Profiles.Tunnelled(Profiles.Profile(Core.Connections.DatabaseEngine.Oracle)));

        var package = session.GetDebugTarget(new Core.Schema.DatabaseObject(new Core.Schema.ObjectName("PROBE", "PKG_CALC"), Core.Schema.ObjectKind.Procedure, Comment: OracleDdl.PackageMarker))!;
        var function = session.GetDebugTarget(new Core.Schema.DatabaseObject(new Core.Schema.ObjectName(null, "F_CALC"), Core.Schema.ObjectKind.Function))!;

        Assert.Equal(PkgCalc.Identity, package.Identity);
        Assert.Equal("Package", package.KindDisplayName);
        Assert.Equal("FUNCTION/APP/F_CALC", function.Identity);
        Assert.Null(session.GetDebugTarget(new Core.Schema.DatabaseObject(new Core.Schema.ObjectName("PROBE", "ORDERS"), Core.Schema.ObjectKind.Table)));
    }

    [Fact]
    public void PayloadsRoundTripNullsAndCharactersOutsideTheBmp()
    {
        string?[] fields = ["0", null, "", "a:b~c", "😀x"];

        var encoded = OracleDebugPayload.Encode(fields);

        Assert.Equal("1:0~0:5:a:b~c2:😀x", encoded);
        Assert.Equal(fields, OracleDebugPayload.Parse(encoded));
        Assert.Equal(fields, OracleDebugPayload.Parse(OracleDebugPayload.Join([encoded[..5], null, encoded[5..]])));
    }

    [Theory]
    [InlineData("x")]
    [InlineData("3:ab")]
    [InlineData("1234567890:a")]
    [InlineData("12")]
    public void AMalformedPayloadIsRefused(string text) => Assert.Throws<FormatException>(() => OracleDebugPayload.Parse(text));

    [Fact]
    public void APauseReadsTheRuntimeRecordAndTheBacktrace()
    {
        // Continue at the breakpoint on ADD_TAX line 6, called from RUN line 14: the macOS app's measured stop.
        var e = OracleDbmsDebugStatements.Event(
        [
            "0", "3", "0", "6", "1",
            "3",
            null, null, "0", "0", "1", null,
            "PROBE", "PKG_CALC", "2", "11", "14", "RUN",
            "PROBE", "PKG_CALC", "2", "11", "6", "ADD_TAX",
        ]);

        Assert.True(e.IsPause);
        Assert.False(e.TimedOut);
        Assert.Equal(6, e.Line);
        Assert.Equal(1, e.Breakpoint);
        Assert.Equal(3, e.Backtrace.Count);
        Assert.Null(e.Backtrace[0].Unit);
        Assert.Equal(PkgCalc, e.Backtrace[2].Unit);
        Assert.Equal("RUN", e.Backtrace[1].EntryPoint);
    }

    [Fact]
    public void TerminationAndTimeoutCarryNoBacktrace()
    {
        var ended = OracleDbmsDebugStatements.Event(["0", "25", "1", null, null, "0"]);
        Assert.True(ended.Terminated);
        Assert.False(ended.IsPause);

        var waiting = OracleDbmsDebugStatements.Event(["31", "2", "0", null, null, "0"]);
        Assert.True(waiting.TimedOut);
        Assert.False(waiting.IsPause);

        Assert.Throws<FormatException>(() => OracleDbmsDebugStatements.Event(["0", "3"]));
    }

    [Fact]
    public void ResumeUsesTheMeasuredBreakFlags()
    {
        Assert.Contains("SYS.DBMS_DEBUG.CONTINUE(l_info, 512, 14)", OracleDbmsDebugStatements.Resume(OracleDbmsDebugStatements.AnyReturn), StringComparison.Ordinal);
        Assert.Contains("CONTINUE(l_info, 32, 14)", OracleDbmsDebugStatements.Resume(OracleDbmsDebugStatements.NextLine), StringComparison.Ordinal);
        Assert.Contains("CONTINUE(l_info, 12, 14)", OracleDbmsDebugStatements.Resume(OracleDbmsDebugStatements.AnyCall), StringComparison.Ordinal);
        Assert.Contains("CONTINUE(l_info, 8192, 14)", OracleDbmsDebugStatements.Resume(OracleDbmsDebugStatements.AbortExecution), StringComparison.Ordinal);
        Assert.Contains("SYS.DBMS_DEBUG.SYNCHRONIZE(l_info, 14)", OracleDbmsDebugStatements.Resume(null), StringComparison.Ordinal);
        Assert.Contains("IF l_status = 0 AND NVL(l_info.Terminated, 0) = 0 THEN", OracleDbmsDebugStatements.Resume(null), StringComparison.Ordinal);
    }

    [Fact]
    public void TheTargetAbortsOnTimeoutAndIsPingedWellWithinIt()
    {
        Assert.Contains("SET_TIMEOUT_BEHAVIOUR(3)", OracleDbmsDebugStatements.TargetSetup, StringComparison.Ordinal);
        Assert.Contains("SET_TIMEOUT(30)", OracleDbmsDebugStatements.TargetSetup, StringComparison.Ordinal);
        Assert.Contains("USING :b1, OUT l_id", OracleDbmsDebugStatements.TargetSetup, StringComparison.Ordinal);
        Assert.Contains("'CALL SYS.DBMS_DEBUG.DEBUG_ON()'", OracleDbmsDebugStatements.TargetSetup, StringComparison.Ordinal);
        Assert.True(OracleDbmsDebugStatements.PingIntervalSeconds * 2 < OracleDbmsDebugStatements.TargetTimeoutSeconds);
        Assert.True(OracleDbmsDebugStatements.SupervisorTimeoutSeconds < OracleDbmsDebugStatements.PingIntervalSeconds);
        Assert.Contains("ATTACH_SESSION(:b1)", OracleDbmsDebugStatements.Attach, StringComparison.Ordinal);
    }

    [Fact]
    public void TheMeasuredLineMapDecodes()
    {
        // GET_LINE_MAP for PROBE.PKG_CALC's body answered maxline 22 and EEFF3F.
        Assert.Equal([1, 2, 3, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21], OracleDbmsDebugStatements.ExecutableLines("EEFF3F", 22));
        Assert.Equal([1, 2, 3, 4, 5, 6, 7], OracleDbmsDebugStatements.ExecutableLines(["0", "8", "FE"]));
        Assert.Null(OracleDbmsDebugStatements.ExecutableLines(["16", null, null]));
        Assert.Empty(OracleDbmsDebugStatements.ExecutableLines(string.Empty, 10));
    }

    [Fact]
    public void ValueStatusesMapToValues()
    {
        var answers = OracleDbmsDebugStatements.ValueAnswers(["0", "1", "32", null, "18", null, "3", null, "40", null], 5);
        var values = answers.Select(a => OracleDbmsDebugStatements.Value(a.Status, a.Value)).ToArray();

        Assert.Equal("1", values[0]!.Display);
        Assert.Null(values[1]!.Display);
        Assert.Equal("Collection", values[2]!.Display);
        Assert.Null(values[3]);
        Assert.Null(values[4]!.Display);
        Assert.Equal("Not readable", OracleDebugValue.Unavailable.Display);
    }

    [Fact]
    public void TheTargetSessionIsIdentifiedForAKill()
    {
        Assert.Equal(new OracleDebugSessionIdentity(213, 28_648, 2), OracleDbmsDebugStatements.SessionIdentity(["213", "28648", "2"]));
        Assert.Equal(new OracleDebugSessionIdentity(213, null, 1), OracleDbmsDebugStatements.SessionIdentity(["213", null, "1"]));
        Assert.Null(OracleDbmsDebugStatements.SessionIdentity([null, null, "1"]));
        Assert.Equal("ALTER SYSTEM KILL SESSION '213,28648' IMMEDIATE", OracleDbmsDebugStatements.KillSession(new OracleDebugSessionIdentity(213, 28_648)));
        Assert.Equal("ALTER SYSTEM KILL SESSION '213,28648,@2' IMMEDIATE", OracleDbmsDebugStatements.KillSession(new OracleDebugSessionIdentity(213, 28_648, 2)));
        Assert.Null(OracleDbmsDebugStatements.KillSession(new OracleDebugSessionIdentity(213, null)));
        Assert.All(OracleDbmsDebugStatements.SessionIdentityQueries, q => Assert.Contains("SYS_CONTEXT('USERENV', 'INSTANCE')", q, StringComparison.Ordinal));
    }

    [Fact]
    public void BreakpointsQuoteNamesAndValuesBindThem()
    {
        var set = OracleDbmsDebugStatements.SetBreakpoint(new OracleDebugUnit("PROBE", "O'NEIL", OracleDebugUnitKind.PackageBody), 6);
        Assert.Contains("l_program.Namespace := 2;", set, StringComparison.Ordinal);
        Assert.Contains("l_program.Name := 'O''NEIL';", set, StringComparison.Ordinal);
        Assert.Contains("SET_BREAKPOINT(l_program, 6, l_number)", set, StringComparison.Ordinal);

        var (block, binds) = OracleDbmsDebugStatements.Values([new OracleDbmsValueRequest("P_AMOUNT", 0, null), new OracleDbmsValueRequest("\"a.b\"", null, PkgCalc)]);
        Assert.Contains("GET_VALUE(:b1, 0, l_value, NULL)", block, StringComparison.Ordinal);
        Assert.Contains("GET_VALUE(:b2, l_handle, l_value, NULL)", block, StringComparison.Ordinal);
        Assert.DoesNotContain("a.b", block, StringComparison.Ordinal);
        Assert.Equal(["P_AMOUNT", "\"a.b\""], binds);
        Assert.Contains("NULL;", OracleDbmsDebugStatements.DeleteBreakpoints([]), StringComparison.Ordinal);
        Assert.Contains("DELETE_BREAKPOINT(2);", OracleDbmsDebugStatements.DeleteBreakpoints([2]), StringComparison.Ordinal);
    }

    [Fact]
    public void PayloadHelpersComeLastInEachDeclareSection()
    {
        foreach (var block in new[]
        {
            OracleDbmsDebugStatements.Resume(0),
            OracleDbmsDebugStatements.SetBreakpoint(PkgCalc, 1),
            OracleDbmsDebugStatements.LineMap(PkgCalc),
            OracleDbmsDebugStatements.Values([new OracleDbmsValueRequest("X", 0, null)]).Block,
        })
        {
            // PL/SQL wants every item declared before the first subprogram.
            Assert.True(block.IndexOf("l_status BINARY_INTEGER;", StringComparison.Ordinal) < block.IndexOf("PROCEDURE put", StringComparison.Ordinal));
            Assert.Contains("OPEN :rows FOR", block, StringComparison.Ordinal);
        }
    }

    [Fact]
    public void ReadinessNeedsDebugInformation()
    {
        Assert.Equal(OracleDebugReadiness.NotVisible, OracleDebugStatements.ReadinessOf(null));
        Assert.Equal(OracleDebugReadiness.Ready, OracleDebugStatements.ReadinessOf(["2", "TRUE"]));
        Assert.Equal(OracleDebugReadiness.Ready, OracleDebugStatements.ReadinessOf(["1", "FALSE"]));
        Assert.Equal(OracleDebugReadiness.NeedsDebugCompile, OracleDebugStatements.ReadinessOf(["2", "FALSE"]));
        Assert.Contains("TYPE = 'PACKAGE BODY'", OracleDebugStatements.Readiness(new OracleDebugUnit("PROBE", "PKG_CALC", OracleDebugUnitKind.Package)), StringComparison.Ordinal);
    }

    [Fact]
    public void AMissingPrivilegeIsNamed()
    {
        Assert.IsType<OracleMissingPrivilege.DebugConnectSession>(OracleDebugStatements.MissingPrivilege(["SCOTT", "0", "0", "0"], PkgCalc));
        Assert.IsType<OracleMissingPrivilege.DebugOnObject>(OracleDebugStatements.MissingPrivilege(["SCOTT", "1", "0", "0"], PkgCalc));
        Assert.Null(OracleDebugStatements.MissingPrivilege(["SCOTT", "1", "1", "0"], PkgCalc));
        Assert.Null(OracleDebugStatements.MissingPrivilege(["PROBE", "1", "0", "0"], PkgCalc));

        var error = OracleDebugText.MissingPrivilege(new OracleMissingPrivilege.DebugOnObject("SCOTT"), PkgCalc);
        Assert.Equal("Debugging PROBE.PKG_CALC needs the DEBUG privilege on it.", error.Message);
        Assert.Contains("GRANT DEBUG ON PROBE.PKG_CALC TO SCOTT", error.Detail, StringComparison.Ordinal);
    }

    [Fact]
    public void EntryPointsGroupArgumentsBySubprogramAndKeepAFunctionsResultApart()
    {
        IReadOnlyList<IReadOnlyList<string?>> rows =
        [
            ["ADD_TAX", "1", "1", "0", null, "NUMBER", "OUT", "N", null, null, null, "NUMBER"],
            ["ADD_TAX", "1", "1", "1", "P_AMOUNT", "NUMBER", "IN", "N", null, null, null, "NUMBER"],
            ["RUN", "2", null, null, null, null, null, null, null, null, null, null],
            ["ADD_TAX", "3", "2", "0", null, "NUMBER", "OUT", "N", null, null, null, "NUMBER"],
            ["ADD_TAX", "3", "2", "1", "P_AMOUNT", "NUMBER", "IN", "N", null, null, null, "NUMBER"],
            ["ADD_TAX", "3", "2", "2", "P_RATE", "NUMBER", "IN", "Y", null, null, null, "NUMBER"],
        ];

        var entryPoints = OracleDebugStatements.ParseEntryPoints(rows, new OracleDebugUnit("PROBE", "PKG_CALC", OracleDebugUnitKind.Package));

        Assert.Equal(["ADD_TAX(P_AMOUNT NUMBER) RETURN NUMBER", "RUN", "ADD_TAX(P_AMOUNT NUMBER, P_RATE NUMBER) RETURN NUMBER"], entryPoints.Select(e => e.DisplayName));
        Assert.Equal(PkgCalc, entryPoints[0].Entry.Unit);
        Assert.Equal(3, entryPoints[2].Entry.SubprogramId);
        Assert.True(entryPoints[2].Parameters[1].HasDefault);
    }

    [Fact]
    public void SourceKeepsTheLinesWhereAllSourceNumbersThem() =>
        Assert.Equal("procedure p is\n\nbegin\n null;\nend;",OracleDebugStatements.AssembleSource([(1, "procedure p is\n"), (3, "begin\r"), (4, " null;\r\n"), (5, "end;")]));

    [Fact]
    public void ErrorCodesAreReadInOrder() =>
        Assert.Equal([6550, 1031], OracleDebugStatements.ErrorCodes("ORA-06550: line 1, column 7:\nORA-01031: insufficient privileges"));

    private static OracleDebugEntryPoint AddTax(int id, params OracleDebugParameter[] parameters) =>
        new(new OracleDebugEntry(PkgCalc, "ADD_TAX", id), null, parameters, new OracleDebugParameter(string.Empty, 0, "NUMBER", OracleDebugParameterMode.Output, false));

    [Fact]
    public void TheInvocationDeclaresEachArgumentAsItsOwnTypeAndBindsTheText()
    {
        var entryPoint = AddTax(
            3,
            new OracleDebugParameter("P_AMOUNT", 1, "NUMBER", OracleDebugParameterMode.Input, false),
            new OracleDebugParameter("P_RATE", 2, "NUMBER", OracleDebugParameterMode.Input, true),
            new OracleDebugParameter("P_WHEN", 3, "DATE", OracleDebugParameterMode.Input, false),
            new OracleDebugParameter("P_TOTAL", 4, "NUMBER", OracleDebugParameterMode.Output, false));

        var invocation = OracleDebugStatements.Invocation(entryPoint, new Dictionary<string, OracleDebugArgument>
        {
            ["P_AMOUNT"] = OracleDebugArgument.Of("10"),
            ["P_WHEN"] = OracleDebugArgument.Null,
        });

        Assert.Equal(["10"], invocation.Binds);
        Assert.Contains("l_arg1 NUMBER;", invocation.Block, StringComparison.Ordinal);
        Assert.Contains("l_arg1 := TO_NUMBER(:b1);", invocation.Block, StringComparison.Ordinal);
        Assert.DoesNotContain("l_arg2", invocation.Block, StringComparison.Ordinal);
        Assert.Contains("l_arg3 DATE;", invocation.Block, StringComparison.Ordinal);
        Assert.Contains("l_result := \"PROBE\".\"PKG_CALC\".\"ADD_TAX\"(\"P_AMOUNT\" => l_arg1, \"P_WHEN\" => l_arg3, \"P_TOTAL\" => l_arg4);", invocation.Block, StringComparison.Ordinal);
        Assert.Contains("put('ADD_TAX');", invocation.Block, StringComparison.Ordinal);
        Assert.Contains("put('P_TOTAL');", invocation.Block, StringComparison.Ordinal);
        Assert.Contains("put('2');", invocation.Block, StringComparison.Ordinal);
        Assert.Contains("OPEN :rows FOR", invocation.Block, StringComparison.Ordinal);
    }

    [Fact]
    public void AnArgumentTextCannotBecomeIsRefused()
    {
        var entryPoint = new OracleDebugEntryPoint(
            new OracleDebugEntry(new OracleDebugUnit("PROBE", "LOAD", OracleDebugUnitKind.Procedure), "LOAD", 1),
            null,
            [new OracleDebugParameter("P_DATA", 1, "BLOB", OracleDebugParameterMode.Input, false), new OracleDebugParameter("P_OBJ", 2, "OBJECT", OracleDebugParameterMode.Input, false)],
            null);

        var blob = Assert.Throws<OracleDebugArgumentException>(() => OracleDebugStatements.Invocation(entryPoint, new Dictionary<string, OracleDebugArgument> { ["P_DATA"] = OracleDebugArgument.Of("00") }));
        Assert.True(blob.Declarable);
        Assert.Equal("Pass NULL or leave it at its default.", OracleDebugText.Argument(blob).Detail);

        var obj = Assert.Throws<OracleDebugArgumentException>(() => OracleDebugStatements.Invocation(entryPoint, new Dictionary<string, OracleDebugArgument>()));
        Assert.False(obj.Declarable);
        Assert.Equal("P_OBJ", obj.Name);
    }

    [Fact]
    public void LeavingOutADefaultThatTellsOverloadsApartAsksForAValue()
    {
        var withNumber = AddTax(1, new OracleDebugParameter("P_RATE", 1, "NUMBER", OracleDebugParameterMode.Input, true));
        var withText = AddTax(2, new OracleDebugParameter("P_RATE", 1, "VARCHAR2", OracleDebugParameterMode.Input, true));
        var arguments = new Dictionary<string, OracleDebugArgument> { ["P_RATE"] = OracleDebugArgument.Default };

        var ambiguity = OracleDebugStatements.Ambiguity(withNumber, arguments, [withNumber, withText])!;
        Assert.Equal(OracleDebugAmbiguityKind.NeedsValue, ambiguity.Kind);
        Assert.Equal(["P_RATE"], ambiguity.Parameters);
        Assert.StartsWith("Give P_RATE a value.", OracleDebugText.Ambiguous(ambiguity, "ADD_TAX").Message, StringComparison.Ordinal);

        Assert.Null(OracleDebugStatements.Ambiguity(withNumber, new Dictionary<string, OracleDebugArgument> { ["P_RATE"] = OracleDebugArgument.Of("1") }, [withNumber, withText]));
    }

    [Fact]
    public void ACallNoValueCanTellApartIsUnresolvable()
    {
        var first = AddTax(1, new OracleDebugParameter("P_RATE", 1, "NUMBER", OracleDebugParameterMode.Input, false));
        var second = AddTax(2, new OracleDebugParameter("P_RATE", 1, "NUMBER", OracleDebugParameterMode.Input, false), new OracleDebugParameter("P_X", 2, "NUMBER", OracleDebugParameterMode.Input, true));

        var ambiguity = OracleDebugStatements.Ambiguity(first, new Dictionary<string, OracleDebugArgument> { ["P_RATE"] = OracleDebugArgument.Of("1") }, [first, second])!;

        Assert.Equal(OracleDebugAmbiguityKind.Unresolvable, ambiguity.Kind);
    }

    [Fact]
    public void TheInvocationReportReadsOutcomeOutputsAndServerOutput()
    {
        var success = OracleDebugStatements.InvocationReport(["S", null, "2", "ADD_TAX", "11", "P_TOTAL", null, "line one", "line two"]);
        Assert.True(success.Succeeded);
        Assert.Equal([("ADD_TAX", (string?)"11"), ("P_TOTAL", null)], success.Outputs);
        Assert.Equal(["line one", "line two"], success.Lines);

        var failure = OracleDebugStatements.InvocationReport(["F", "ORA-01476: divisor is equal to zero", "0"]);
        Assert.False(failure.Succeeded);
        Assert.Equal("ORA-01476: divisor is equal to zero", failure.Error);
    }

    [Fact]
    public void OnlyTheServersOwnAnswerProvesACallEndedThere()
    {
        Assert.True(new OracleDebugServerException(6543, "ORA-06543").AnsweredByServer);
        Assert.False(new OracleDebugServerException(3113, "ORA-03113: end-of-file on communication channel").AnsweredByServer);
        Assert.False(new OracleDebugServerException(12570, "ORA-12570").AnsweredByServer);
        Assert.False(new OracleDebugServerException(50000, "Connection request timed out").AnsweredByServer);
        Assert.True(new OracleDebugCallResult([], null).EndedOnServer);
        Assert.False(new OracleDebugCallResult(null, new IOException()).EndedOnServer);
    }

    [Fact]
    public void ABreakpointHeldByTwoLinesComesOffOnlyWhenTheLastLetsGo()
    {
        // One sent at start on line 4 landed on 5, and the user then set 5 itself.
        var holds = new OracleDebugBreakpointHolds();
        holds.Hold(5, PkgCalc, 4);
        holds.Hold(5, PkgCalc, 5);

        Assert.Null(holds.Release(4, PkgCalc));
        Assert.Equal(5, holds.Release(5, PkgCalc));
        Assert.Equal(9, holds.Release(9, PkgCalc));
    }
}
