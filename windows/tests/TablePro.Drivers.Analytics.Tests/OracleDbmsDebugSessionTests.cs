using System.Collections.Concurrent;
using System.Globalization;
using TablePro.Core.Drivers;
using TablePro.Drivers.Oracle;

namespace TablePro.Drivers.Analytics.Tests;

/// <summary>
/// The DBMS_DEBUG engine against recorded answers: a scripted target whose call blocks as a target paused at the
/// supervisor does, and a scripted supervisor that answers each DBMS_DEBUG block with the payload the package would.
/// </summary>
public sealed class OracleDbmsDebugSessionTests
{
    private const string InvocationBlock = "BEGIN PROBE.RUN_CALC; END;";

    private static readonly OracleDebugUnit RunCalc = new("PROBE", "RUN_CALC", OracleDebugUnitKind.Procedure);

    private static readonly string?[] AnonymousFrame = [null, null, "0", null, "1", null];

    private static readonly string?[] RunCalcFrame = ["PROBE", "RUN_CALC", "1", "7", "3", null];

    private static readonly string[] Source =
    [
        "procedure run_calc is\n",
        "  l_total number := 0;\n",
        "begin\n",
        "  l_total := l_total + 1;\n",
        "  dbms_output.put_line(l_total);\n",
        "  null;\n",
        "end run_calc;",
    ];

    // Lines 3, 5 and 7 have code.
    private static readonly IReadOnlyList<string?> LineMap = Payload("0", "7", "A8");

    private static IReadOnlyList<string?> Payload(params string?[] fields) => [OracleDebugPayload.Encode(fields)];

    private static IReadOnlyList<string?> Event(bool terminated = false, int? line = null, int? breakpoint = null, params string?[][] frames)
    {
        string?[] head =
        [
            "0",
            terminated ? "25" : "3",
            terminated ? "1" : "0",
            line?.ToString(CultureInfo.InvariantCulture),
            breakpoint?.ToString(CultureInfo.InvariantCulture),
            frames.Length.ToString(CultureInfo.InvariantCulture),
        ];
        return Payload([.. head, .. frames.SelectMany(f => f)]);
    }

    private static bool IsContinue(string sql, int flags) => sql.Contains(string.Create(CultureInfo.InvariantCulture, $"CONTINUE(l_info, {flags},"), StringComparison.Ordinal);

    /// <summary>A target whose call waits for <see cref="Ended"/>, and a supervisor that opens it on an abort.</summary>
    private sealed class Rig
    {
        public Rig(Func<string, IReadOnlyList<string?>?> supervisor, TimeSpan? callEndWait = null)
        {
            Target = new ScriptedOracleChannel(async sql =>
            {
                if (sql != InvocationBlock)
                {
                    return [];
                }

                await Ended.Task;
                return CallResult();
            });
            Supervisor = new ScriptedOracleChannel(sql =>
            {
                if (IsContinue(sql, OracleDbmsDebugStatements.AbortExecution))
                {
                    Ended.TrySetResult();
                    return Task.FromResult(Event(terminated: true));
                }

                return Task.FromResult(supervisor(sql) ?? []);
            });
            Session = new OracleDbmsDebugSession(
                Target,
                Supervisor,
                new OracleDebugEntryPoint(new OracleDebugEntry(RunCalc, "RUN_CALC", 1), null, [], null),
                new OracleDebugInvocation(InvocationBlock, []),
                callEndWait);
        }

        public TaskCompletionSource Ended { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);

        public Func<IReadOnlyList<string?>> CallResult { get; set; } = () => throw new OracleDebugServerException(6543, "ORA-06543: PL/SQL: execution aborted");

        public ScriptedOracleChannel Target { get; }

        public ScriptedOracleChannel Supervisor { get; }

        public OracleDbmsDebugSession Session { get; }
    }

    /// <summary>The recorded answers of a run paused at line 3 of RUN_CALC, entered through its header breakpoint.</summary>
    private static IReadOnlyList<string?>? PausedAtThree(string sql)
    {
        if (sql.Contains("GET_LINE_MAP", StringComparison.Ordinal))
        {
            return LineMap;
        }

        if (sql.Contains("SYNCHRONIZE", StringComparison.Ordinal))
        {
            return Event(line: 1, frames: AnonymousFrame);
        }

        if (sql.Contains("SET_BREAKPOINT(l_program, 3,", StringComparison.Ordinal))
        {
            return Payload("0", "1");
        }

        if (sql.Contains("SET_BREAKPOINT(l_program, 5,", StringComparison.Ordinal))
        {
            return Payload("0", "2");
        }

        return IsContinue(sql, OracleDbmsDebugStatements.BreakpointsOnly) ? Event(line: 3, breakpoint: 1, frames: [AnonymousFrame, RunCalcFrame]) : null;
    }

    [Fact]
    public async Task TheStartArmsTheTargetAndAttachesTheSupervisorWithTheSameId()
    {
        var rig = new Rig(PausedAtThree);
        await rig.Session.StartAsync([], TestContext.Current.CancellationToken);

        var setup = Assert.Single(rig.Target.Executed, e => e.Sql.Contains("DEBUG_ON", StringComparison.Ordinal));
        var attach = Assert.Single(rig.Supervisor.Executed, e => e.Sql.Contains("ATTACH_SESSION", StringComparison.Ordinal));
        Assert.StartsWith("TP", setup.Binds[0], StringComparison.Ordinal);
        Assert.Equal(setup.Binds, attach.Binds);
        Assert.Contains(rig.Supervisor.Sent, s => s.Contains("CURRENT_SCHEMA", StringComparison.Ordinal));
        Assert.True(rig.Session.Output.TryRead(out var first));
        Assert.Equal(OracleDebugText.UsingDbmsDebug, first);
        rig.Ended.TrySetResult();
    }

    [Fact]
    public async Task TheFirstStopEntersThroughTheHeaderBreakpointAndRemovesIt()
    {
        var rig = new Rig(PausedAtThree);
        await rig.Session.StartAsync([], TestContext.Current.CancellationToken);

        var stop = Assert.IsType<DebugStop.Paused>(await rig.Session.FirstStopAsync(TestContext.Current.CancellationToken));

        Assert.Equal(new DebugUnit(RunCalc.Identity, "PROBE.RUN_CALC"), stop.Location.Unit);
        Assert.Equal(3, stop.Location.Line);
        Assert.Contains(rig.Supervisor.Sent, s => s.Contains("DELETE_BREAKPOINT(1);", StringComparison.Ordinal));
        Assert.Contains(rig.Target.Sent, s => s == InvocationBlock);
        Assert.True((await rig.Session.StopAsync()).Confirmed);
    }

    [Fact]
    public async Task APausedFrameAnswersItsStackSourceAndScannedVariables()
    {
        var rig = new Rig(sql => sql.Contains("GET_VALUE", StringComparison.Ordinal) ? Payload("0", "0") : PausedAtThree(sql));
        rig.Supervisor.Rows = sql => sql.Contains("ALL_SOURCE", StringComparison.Ordinal)
            ? [.. Source.Select((text, i) => (IReadOnlyList<string?>)[(i + 1).ToString(CultureInfo.InvariantCulture), text])]
            : null;
        await rig.Session.StartAsync([], TestContext.Current.CancellationToken);
        await rig.Session.FirstStopAsync(TestContext.Current.CancellationToken);

        var frame = Assert.Single(await rig.Session.GetStackAsync(TestContext.Current.CancellationToken));
        Assert.Equal(3, frame.Location!.Line);
        Assert.Contains("l_total := l_total + 1;", await rig.Session.GetSourceAsync(frame.Location.Unit, TestContext.Current.CancellationToken), StringComparison.Ordinal);

        var variable = Assert.Single(await rig.Session.GetVariablesAsync(0, TestContext.Current.CancellationToken));
        Assert.Equal(new DebugVariable("L_TOTAL", DebugVariableKind.Local, "NUMBER", "0", false), variable);
        var read = Assert.Single(rig.Supervisor.Executed, e => e.Sql.Contains("GET_VALUE", StringComparison.Ordinal));
        Assert.Equal(["L_TOTAL"], read.Binds);
        Assert.Contains("GET_VALUE(:b1, 0, l_value, NULL)", read.Sql, StringComparison.Ordinal);
        Assert.True((await rig.Session.StopAsync()).Confirmed);
    }

    [Fact]
    public async Task StopAbortsATargetAFailedFirstStopLeftPaused()
    {
        // The target paused at the supervisor, then an answer the first stop read did not parse. The target is still
        // paused, so the stop aborts it there, which needs no ALTER SYSTEM, and the run ends confirmed.
        var rig = new Rig(sql =>
            sql.Contains("SYNCHRONIZE", StringComparison.Ordinal) ? Event(line: 1, frames: AnonymousFrame)
            : sql.Contains("GET_LINE_MAP", StringComparison.Ordinal) ? ["not a payload"]
            : null);
        await rig.Session.StartAsync([], TestContext.Current.CancellationToken);

        var error = await Assert.ThrowsAsync<RoutineDebugException>(() => rig.Session.FirstStopAsync(TestContext.Current.CancellationToken));
        Assert.Equal(OracleDebugText.Unreadable, error.Message);

        Assert.True((await rig.Session.StopAsync()).Confirmed);
        Assert.Contains(rig.Supervisor.Sent, s => IsContinue(s, OracleDbmsDebugStatements.AbortExecution));
        Assert.DoesNotContain(rig.Supervisor.Sent, s => s.Contains("ALTER SYSTEM KILL", StringComparison.Ordinal));
        Assert.Contains("ROLLBACK", rig.Target.Sent);
    }

    [Theory]
    [InlineData(3113, false)]
    [InlineData(6543, true)]
    public async Task StopConfirmsTheEndOnlyFromTheServersAnswer(int code, bool serverAnswered)
    {
        var rig = new Rig(PausedAtThree) { CallResult = () => throw new OracleDebugServerException(code, $"ORA-{code:D5}") };
        await rig.Session.StartAsync([], TestContext.Current.CancellationToken);
        Assert.IsType<DebugStop.Paused>(await rig.Session.FirstStopAsync(TestContext.Current.CancellationToken));

        var outcome = await rig.Session.StopAsync();

        Assert.Equal(serverAnswered, outcome.Confirmed);
        Assert.Equal(!serverAnswered, rig.Supervisor.Sent.Any(s => s.StartsWith("ALTER SYSTEM KILL SESSION '42,7'", StringComparison.Ordinal)));
        if (!serverAnswered)
        {
            Assert.Equal(OracleDebugText.StillRunning, outcome.Message);
            Assert.Contains("SID 42, SERIAL# 7", outcome.Detail, StringComparison.Ordinal);
        }
    }

    [Fact]
    public async Task ARunWhoseCallStillRunsEndsUnconfirmedWithoutQueueingARollback()
    {
        var rig = new Rig(sql => sql.Contains("SYNCHRONIZE", StringComparison.Ordinal) ? Event(terminated: true) : null, TimeSpan.FromMilliseconds(200));
        await rig.Session.StartAsync([], TestContext.Current.CancellationToken);

        var stop = Assert.IsType<DebugStop.Failed>(await rig.Session.FirstStopAsync(TestContext.Current.CancellationToken).WaitAsync(TimeSpan.FromSeconds(5), TestContext.Current.CancellationToken));

        Assert.Equal(OracleDebugText.StillRunning, stop.Message);
        Assert.DoesNotContain("ROLLBACK", rig.Target.Sent);
        rig.Ended.TrySetResult();
    }

    [Fact]
    public async Task AFinishedRoutineCommitsAndReturnsItsOutputsAndServerOutput()
    {
        var rig = new Rig(sql =>
            IsContinue(sql, OracleDbmsDebugStatements.NextLine) ? Event(terminated: true) : PausedAtThree(sql))
        {
            CallResult = () => [OracleDebugPayload.Encode(["S", null, "1", "P_TOTAL", "11", "total=11"])],
        };
        await rig.Session.StartAsync([], TestContext.Current.CancellationToken);
        await rig.Session.FirstStopAsync(TestContext.Current.CancellationToken);
        rig.Ended.TrySetResult();

        var finished = Assert.IsType<DebugStop.Finished>(await rig.Session.PerformAsync(DebugCommand.StepOver, TestContext.Current.CancellationToken));

        Assert.Equal("P_TOTAL", finished.Result!.Columns[0].Name);
        Assert.Equal("11", finished.Result[0, 0]);
        Assert.Contains("COMMIT", rig.Target.Sent);
        Assert.DoesNotContain("ROLLBACK", rig.Target.Sent);
        var output = new List<string>();
        await foreach (var line in rig.Session.Output.ReadAllAsync(TestContext.Current.CancellationToken))
        {
            output.Add(line);
        }

        Assert.Equal([OracleDebugText.UsingDbmsDebug, "total=11"], output);
    }

    [Fact]
    public async Task ARoutineThatRaisedRollsBackAndSaysWhy()
    {
        // The first continue reaches the entry breakpoint; the second runs the routine to its end.
        var continues = 0;
        var rig = new Rig(sql =>
            IsContinue(sql, OracleDbmsDebugStatements.BreakpointsOnly) && Interlocked.Increment(ref continues) > 1 ? Event(terminated: true) : PausedAtThree(sql))
        {
            CallResult = () => [OracleDebugPayload.Encode(["F", "ORA-01476: divisor is equal to zero", "0"])],
        };
        await rig.Session.StartAsync([], TestContext.Current.CancellationToken);
        await rig.Session.FirstStopAsync(TestContext.Current.CancellationToken);
        rig.Ended.TrySetResult();

        var failed = Assert.IsType<DebugStop.Failed>(await rig.Session.PerformAsync(DebugCommand.Continue, TestContext.Current.CancellationToken));

        Assert.Equal(OracleDebugText.RoutineFailed, failed.Message);
        Assert.Equal("ORA-01476: divisor is equal to zero", failed.Detail);
        Assert.Contains("ROLLBACK", rig.Target.Sent);
    }

    [Fact]
    public async Task EachCommandSendsItsMeasuredBreakFlags()
    {
        var rig = new Rig(sql =>
            IsContinue(sql, OracleDbmsDebugStatements.AnyReturn) || IsContinue(sql, OracleDbmsDebugStatements.AnyCall)
                ? Event(line: 5, frames: [AnonymousFrame, RunCalcFrame])
                : PausedAtThree(sql));
        await rig.Session.StartAsync([], TestContext.Current.CancellationToken);
        await rig.Session.FirstStopAsync(TestContext.Current.CancellationToken);

        Assert.Equal(5, Assert.IsType<DebugStop.Paused>(await rig.Session.PerformAsync(DebugCommand.StepOut, TestContext.Current.CancellationToken)).Location.Line);
        Assert.Equal(5, Assert.IsType<DebugStop.Paused>(await rig.Session.PerformAsync(DebugCommand.StepInto, TestContext.Current.CancellationToken)).Location.Line);
        Assert.Contains(DebugCommand.StepOut, rig.Session.SupportedCommands);
        Assert.True((await rig.Session.StopAsync()).Confirmed);
    }

    [Fact]
    public async Task ARefusedDeleteCanBeRetried()
    {
        var refusals = 1;
        var rig = new Rig(sql =>
        {
            if (sql.Contains("DELETE_BREAKPOINT(2)", StringComparison.Ordinal) && Interlocked.Decrement(ref refusals) >= 0)
            {
                throw new OracleDebugServerException(6550, "ORA-06550");
            }

            return PausedAtThree(sql);
        });
        await rig.Session.StartAsync([(RunCalc, 5)], TestContext.Current.CancellationToken);
        Assert.IsType<DebugStop.Paused>(await rig.Session.FirstStopAsync(TestContext.Current.CancellationToken));
        var breakpoint = new DebugBreakpoint(RunCalc.Identity, 5);

        await Assert.ThrowsAsync<RoutineDebugException>(() => rig.Session.RemoveBreakpointAsync(breakpoint, TestContext.Current.CancellationToken));
        await rig.Session.RemoveBreakpointAsync(breakpoint, TestContext.Current.CancellationToken);

        Assert.Equal(2, rig.Supervisor.Sent.Count(s => s.Contains("DELETE_BREAKPOINT(2)", StringComparison.Ordinal)));
        Assert.True((await rig.Session.StopAsync()).Confirmed);
    }

    [Fact]
    public async Task AStartBreakpointIsRemovedByTheLineItWasAskedFor()
    {
        // Sent at start on line 4, it lands on line 5; the caller never learns that and removes it by line 4.
        var rig = new Rig(PausedAtThree);
        await rig.Session.StartAsync([(RunCalc, 4)], TestContext.Current.CancellationToken);
        Assert.IsType<DebugStop.Paused>(await rig.Session.FirstStopAsync(TestContext.Current.CancellationToken));

        await rig.Session.RemoveBreakpointAsync(new DebugBreakpoint(RunCalc.Identity, 4), TestContext.Current.CancellationToken);

        Assert.Contains(rig.Supervisor.Sent, s => s.Contains("DELETE_BREAKPOINT(2)", StringComparison.Ordinal));
        Assert.True((await rig.Session.StopAsync()).Confirmed);
    }

    [Fact]
    public async Task ABreakpointSetWhilePausedMovesToTheNextLineWithCodeOrIsRefused()
    {
        var rig = new Rig(PausedAtThree);
        await rig.Session.StartAsync([], TestContext.Current.CancellationToken);
        await rig.Session.FirstStopAsync(TestContext.Current.CancellationToken);

        var placed = await rig.Session.SetBreakpointAsync(new DebugBreakpoint(RunCalc.Identity, 4), TestContext.Current.CancellationToken);

        Assert.Equal(5, placed!.Line);
        Assert.Null(await rig.Session.SetBreakpointAsync(new DebugBreakpoint(RunCalc.Identity, 9), TestContext.Current.CancellationToken));
        Assert.True((await rig.Session.StopAsync()).Confirmed);
    }

    [Fact]
    public async Task ALaunchWithAnAmbiguousDefaultIsRefusedAndClosesBothChannels()
    {
        var target = new ScriptedOracleChannel(_ => Task.FromResult<IReadOnlyList<string?>>([]));
        var supervisor = new ScriptedOracleChannel(_ => Task.FromResult<IReadOnlyList<string?>>([]));
        var unit = new OracleDebugUnit("PROBE", "PKG_CALC", OracleDebugUnitKind.PackageBody);
        var number = new OracleDebugEntryPoint(new OracleDebugEntry(unit, "ADD_TAX", 1), null, [new OracleDebugParameter("P_RATE", 1, "NUMBER", OracleDebugParameterMode.Input, true)], null);
        var text = new OracleDebugEntryPoint(new OracleDebugEntry(unit, "ADD_TAX", 2), null, [new OracleDebugParameter("P_RATE", 1, "VARCHAR2", OracleDebugParameterMode.Input, true)], null);
        var request = new RoutineDebugRequest(new DebugEntryPoint(number.Entry.Identity, number.DisplayName, []), [new DebugArgument("P_RATE", DebugArgumentValue.Default)], []);

        var error = await Assert.ThrowsAsync<RoutineDebugException>(() => OracleDbmsDebugSession.LaunchAsync(target, supervisor, number, [number, text], request, TestContext.Current.CancellationToken));

        Assert.StartsWith("Give P_RATE a value.", error.Message, StringComparison.Ordinal);
        Assert.True(target.Disposed && supervisor.Disposed);
        Assert.Empty(target.Sent);
    }

    [Fact]
    public async Task AMissingDebugConnectSessionAtStartIsNamed()
    {
        var target = new ScriptedOracleChannel(sql => sql.Contains("INITIALIZE", StringComparison.Ordinal)
            ? Task.FromException<IReadOnlyList<string?>>(new OracleDebugServerException(1031, "ORA-01031: insufficient privileges"))
            : Task.FromResult<IReadOnlyList<string?>>([]));
        var supervisor = new ScriptedOracleChannel(_ => Task.FromResult<IReadOnlyList<string?>>([]));
        var entryPoint = new OracleDebugEntryPoint(new OracleDebugEntry(RunCalc, "RUN_CALC", 1), null, [], null);
        var request = new RoutineDebugRequest(new DebugEntryPoint(entryPoint.Entry.Identity, "RUN_CALC", []), [], []);

        var error = await Assert.ThrowsAsync<RoutineDebugException>(() => OracleDbmsDebugSession.LaunchAsync(target, supervisor, entryPoint, [entryPoint], request, TestContext.Current.CancellationToken));

        Assert.Equal("Debugging needs the DEBUG CONNECT SESSION privilege.", error.Message);
        Assert.True(target.Disposed && supervisor.Disposed);
    }
}

/// <summary>A session that answers each statement through its script, one at a time as a real one does, and records it.</summary>
internal sealed class ScriptedOracleChannel(Func<string, Task<IReadOnlyList<string?>>> respond) : IOracleDebugChannel
{
    private readonly SemaphoreSlim _gate = new(1, 1);

    public Func<string, IReadOnlyList<IReadOnlyList<string?>>?> Rows { get; set; } = _ => null;

    public ConcurrentQueue<string> Sent { get; } = new();

    public ConcurrentQueue<(string Sql, IReadOnlyList<string?> Binds)> Executed { get; } = new();

    public bool Disposed { get; private set; }

    public int Cancels;

    public async Task<IReadOnlyList<string?>> ExecuteAsync(string sql, IReadOnlyList<string?>? binds = null, bool readsRows = false, CancellationToken cancellationToken = default)
    {
        Sent.Enqueue(sql);
        Executed.Enqueue((sql, binds ?? []));
        await _gate.WaitAsync(CancellationToken.None);
        try
        {
            await Task.Yield();
            return await respond(sql);
        }
        finally
        {
            _gate.Release();
        }
    }

    public Task<IReadOnlyList<IReadOnlyList<string?>>> QueryAsync(string sql, CancellationToken cancellationToken = default)
    {
        Sent.Enqueue(sql);
        IReadOnlyList<IReadOnlyList<string?>> identity = [["42", "7", null]];
        return Task.FromResult(Rows(sql) ?? (sql.Contains("SESSION", StringComparison.Ordinal) ? identity : []));
    }

    public void Cancel() => Interlocked.Increment(ref Cancels);

    public ValueTask DisposeAsync()
    {
        Disposed = true;
        return ValueTask.CompletedTask;
    }
}
