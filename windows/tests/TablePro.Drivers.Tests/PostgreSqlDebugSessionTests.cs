using System.Collections.Concurrent;
using TablePro.Core.Drivers;
using TablePro.Core.Results;
using TablePro.Drivers.PostgreSql;

namespace TablePro.Drivers.Tests;

/// <summary>
/// The PL/pgSQL session against recorded pldbgapi replies: a scripted target that announces its port and blocks in its
/// call, and a scripted proxy that answers each pldbgapi function as the extension does.
/// </summary>
public sealed class PostgreSqlDebugSessionTests
{
    private static readonly DebugEntryPoint Entry = new("16384", "add_tax(p_amount numeric, p_rate numeric)", []);

    private static readonly ResultSet Eleven = new([new ResultColumn("add_tax", "numeric", typeof(decimal))], [[11m]]);

    private static RoutineDebugRequest Request(params DebugBreakpoint[] breakpoints) =>
        new(Entry, [new DebugArgument("p_amount", DebugArgumentValue.FromText("10")), new DebugArgument("p_rate", DebugArgumentValue.Default)], breakpoints);

    private static IReadOnlyList<IReadOnlyList<string?>> Rows(params string?[][] rows) => [.. rows];

    /// <summary>A target and proxy wired as pldebugger behaves: the call announces port 7 and blocks until it ends.</summary>
    private sealed class Rig
    {
        public Rig()
        {
            Target.Call = async call =>
            {
                Target.RaiseNotice(Announce);
                return await CallEnd.Task;
            };
            Proxy.Respond = (sql, _) => ProxyReply(sql);
        }

        public string Announce { get; set; } = "PLDBGBREAK:7";

        public ScriptedPgConnection Target { get; } = new() { Name = "target" };

        public ScriptedPgConnection Proxy { get; } = new() { Name = "proxy" };

        public TaskCompletionSource<ResultSet> CallEnd { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);

        /// <summary>A reply for the statements a test scripts itself; null leaves the statement to the recorded replies.</summary>
        public Func<string, Task<IReadOnlyList<IReadOnlyList<string?>>>?> Steps { get; set; } = _ => null;

        public ConcurrentQueue<ScriptedPgConnection> Opened { get; } = new();

        public Task<PostgreSqlRoutineDebugSession> StartAsync(RoutineDebugRequest request, TimeSpan? budget = null) =>
            StartUntilAsync(request, budget, TestContext.Current.CancellationToken);

        public Task<PostgreSqlRoutineDebugSession> StartUntilAsync(RoutineDebugRequest request, TimeSpan? budget, CancellationToken cancellationToken) =>
            PostgreSqlRoutineDebugSession.StartAsync(Target, Proxy, OpenAsync, request, cancellationToken, budget ?? TimeSpan.FromMilliseconds(600));

        private Task<IPostgreSqlDebugConnection> OpenAsync(CancellationToken cancellationToken)
        {
            var rescue = new ScriptedPgConnection { Name = "rescue" };
            rescue.Respond = (sql, _) => ProxyReply(sql);
            Opened.Enqueue(rescue);
            return Task.FromResult<IPostgreSqlDebugConnection>(rescue);
        }

        private Task<IReadOnlyList<IReadOnlyList<string?>>> ProxyReply(string sql) => Steps(sql) ?? Task.FromResult(Recorded(sql));

        private IReadOnlyList<IReadOnlyList<string?>> Recorded(string sql)
        {
            if (sql.Contains("current_database()", StringComparison.Ordinal))
            {
                return Rows(PostgreSqlDebugProtocolTests.RoutineRow());
            }

            if (sql.Contains("pldbg_attach_to_port(7)", StringComparison.Ordinal))
            {
                return Rows(["1"]);
            }

            if (sql.Contains("pldbg_wait_for_breakpoint(1)", StringComparison.Ordinal))
            {
                return Rows(["16384", "4", "add_tax"]);
            }

            if (sql.Contains("pldbg_set_breakpoint", StringComparison.Ordinal) || sql.Contains("pldbg_drop_breakpoint", StringComparison.Ordinal))
            {
                return Rows(["t"]);
            }

            if (sql.Contains("pldbg_get_source", StringComparison.Ordinal))
            {
                return Rows(["\nBEGIN\n  RETURN p_amount * (1 + p_rate);\nEND;\n"]);
            }

            if (sql.Contains("pldbg_get_stack", StringComparison.Ordinal))
            {
                return Rows(["0", "add_tax", "16384", "3", "p_amount=10"], ["1", "run", "16390", "9", "p_n=3"]);
            }

            if (sql.Contains("pldbg_get_variables", StringComparison.Ordinal))
            {
                return Rows(["p_amount", "A", "0", "t", "f", "f", "numeric", "10"], ["l_tax", "L", "3", "t", "f", "f", "numeric", "NULL"]);
            }

            if (sql.Contains("pldbg_select_frame", StringComparison.Ordinal))
            {
                return Rows(["16390", "10", "run"]);
            }

            if (sql.Contains("pldbg_abort_target", StringComparison.Ordinal))
            {
                CallEnd.TrySetException(new PostgreSqlDebugServerException("57014", "canceling statement due to user request"));
                return Rows(["t"]);
            }

            return Rows();
        }
    }

    [Fact]
    public async Task TheStartArmsTheTargetAndAttachesTheProxyToTheAnnouncedBackend()
    {
        var rig = new Rig();

        await using var session = await rig.StartAsync(Request());

        Assert.Equal(["ROLLBACK", "SET statement_timeout = 0", "SET idle_session_timeout = 0", "SET transaction_timeout = 0", "SET client_min_messages = notice"], rig.Target.Sent.Take(5));
        Assert.Contains(rig.Target.Sent, s => s == "SELECT \"public\".pldbg_oid_debug('16384'::pg_catalog.oid)");
        Assert.Contains(rig.Target.Sent, s => s == "SELECT * FROM \"public\".\"add_tax\"($1::\"pg_catalog\".\"numeric\", (0.1)::\"pg_catalog\".\"numeric\")");
        Assert.Equal(["10"], rig.Target.Parameters.Single());
        Assert.Contains(rig.Proxy.Sent, s => s.Contains("pldbg_attach_to_port(7)", StringComparison.Ordinal));
    }

    [Fact]
    public async Task TheFirstStopPausesAtTheSourceLineAndPlacesTheStartBreakpointsAfterIt()
    {
        var rig = new Rig();
        await using var session = await rig.StartAsync(Request(new DebugBreakpoint("16384", 3)));

        var stop = Assert.IsType<DebugStop.Paused>(await session.FirstStopAsync(TestContext.Current.CancellationToken));

        Assert.Equal(3, stop.Location.Line);
        var wait = rig.Proxy.Sent.ToList().FindIndex(s => s.Contains("pldbg_wait_for_breakpoint", StringComparison.Ordinal));
        var place = rig.Proxy.Sent.ToList().FindIndex(s => s.Contains("pldbg_set_breakpoint(1, '16384'::pg_catalog.oid, 3)", StringComparison.Ordinal));
        Assert.True(wait >= 0 && place > wait);
    }

    [Fact]
    public async Task APausedTargetAnswersItsSourceStackAndVariables()
    {
        var rig = new Rig();
        await using var session = await rig.StartAsync(Request());
        await session.FirstStopAsync(TestContext.Current.CancellationToken);

        Assert.Contains("RETURN p_amount", await session.GetSourceAsync(new DebugUnit("16384", "add_tax"), TestContext.Current.CancellationToken), StringComparison.Ordinal);
        var stack = await session.GetStackAsync(TestContext.Current.CancellationToken);
        Assert.Equal([3, 9], stack.Select(f => f.Location!.Line));
        var variables = await session.GetVariablesAsync(0, TestContext.Current.CancellationToken);
        Assert.Equal(["p_amount", "l_tax"], variables.Select(v => v.Name));
        Assert.Null(variables[1].Value);
        Assert.DoesNotContain(rig.Proxy.Sent, s => s.Contains("pldbg_select_frame", StringComparison.Ordinal));

        await session.GetVariablesAsync(1, TestContext.Current.CancellationToken);
        Assert.Contains(rig.Proxy.Sent, s => s.Contains("pldbg_select_frame(1, 1)", StringComparison.Ordinal));
    }

    [Fact]
    public async Task ARoutineThatReturnsWithoutPausingAgainFinishesWithItsResult()
    {
        // The target keeps its debugger socket, so the proxy's continue never answers; the call ending is the signal.
        var rig = new Rig();
        var neverAnswers = new TaskCompletionSource<IReadOnlyList<IReadOnlyList<string?>>>();
        rig.Steps = sql => sql.Contains("pldbg_continue", StringComparison.Ordinal) ? neverAnswers.Task : null;
        rig.Target.Respond = (sql, _) => Task.FromResult<IReadOnlyList<IReadOnlyList<string?>>>(
            sql.Contains("prosrc", StringComparison.Ordinal) ? Rows(["\nBEGIN\n  RETURN p_amount;\nEND;\n"]) : Rows());
        await using var session = await rig.StartAsync(Request());
        await session.FirstStopAsync(TestContext.Current.CancellationToken);

        var step = session.PerformAsync(DebugCommand.Continue, TestContext.Current.CancellationToken);
        rig.CallEnd.SetResult(Eleven);
        var finished = Assert.IsType<DebugStop.Finished>(await step.WaitAsync(TimeSpan.FromSeconds(5), TestContext.Current.CancellationToken));

        Assert.Same(Eleven, finished.Result);

        // Once the call returned, the target's own connection is free to read the source the proxy no longer can.
        Assert.Contains("RETURN p_amount", await session.GetSourceAsync(new DebugUnit("16384", "add_tax"), TestContext.Current.CancellationToken), StringComparison.Ordinal);
        Assert.True((await session.StopAsync()).Confirmed);
        neverAnswers.SetResult(Rows());
    }

    [Fact]
    public async Task ARoutineErrorEndsTheRunWithTheServersMessage()
    {
        var rig = new Rig();
        rig.Steps = sql =>
        {
            if (!sql.Contains("pldbg_step_over", StringComparison.Ordinal))
            {
                return null;
            }

            rig.CallEnd.TrySetException(new PostgreSqlDebugServerException("P0001", "rate too high", where: "PL/pgSQL function add_tax(numeric,numeric) line 3 at RAISE"));
            return Task.FromException<IReadOnlyList<IReadOnlyList<string?>>>(new PostgreSqlDebugServerException("08006", "debugger connection terminated"));
        };
        await using var session = await rig.StartAsync(Request());
        await session.FirstStopAsync(TestContext.Current.CancellationToken);

        var failed = Assert.IsType<DebugStop.Failed>(await session.PerformAsync(DebugCommand.StepOver, TestContext.Current.CancellationToken));

        Assert.Equal("rate too high", failed.Message);
        Assert.Equal("PL/pgSQL function add_tax(numeric,numeric) line 3 at RAISE", failed.Detail);
    }

    [Fact]
    public async Task StepOutIsRefused()
    {
        var rig = new Rig();
        await using var session = await rig.StartAsync(Request());
        await session.FirstStopAsync(TestContext.Current.CancellationToken);

        var error = await Assert.ThrowsAsync<RoutineDebugException>(() => session.PerformAsync(DebugCommand.StepOut, TestContext.Current.CancellationToken));
        Assert.Equal("The PL/pgSQL debugger can't step out of a routine.", error.Message);
    }

    [Fact]
    public async Task StopWhilePausedAbortsThroughTheProxyAndConfirmsTheEnd()
    {
        var rig = new Rig();
        await using var session = await rig.StartAsync(Request());
        await session.FirstStopAsync(TestContext.Current.CancellationToken);

        var outcome = await session.StopAsync();

        Assert.True(outcome.Confirmed);
        Assert.Contains(rig.Proxy.Sent, s => s.Contains("pldbg_abort_target(1)", StringComparison.Ordinal));
        Assert.Equal(PostgreSqlDebugProtocol.StoppedMessage, Assert.IsType<DebugStop.Failed>(await session.PerformAsync(DebugCommand.Continue, TestContext.Current.CancellationToken)).Message);
        await Assert.ThrowsAsync<OperationCanceledException>(() => session.GetSourceAsync(new DebugUnit("16384", "add_tax"), TestContext.Current.CancellationToken));
    }

    [Fact]
    public async Task StopWhileAStepWaitsCancelsTheTargetNeverTheProxy()
    {
        var rig = new Rig();
        var continued = new TaskCompletionSource<IReadOnlyList<IReadOnlyList<string?>>>();
        rig.Steps = sql => sql.Contains("pldbg_continue", StringComparison.Ordinal) ? continued.Task : null;
        rig.Target.OnCancel = () => rig.CallEnd.TrySetException(new PostgreSqlDebugServerException("57014", "canceling statement due to user request"));
        await using var session = await rig.StartAsync(Request());
        await session.FirstStopAsync(TestContext.Current.CancellationToken);

        var step = Task.Run(() => session.PerformAsync(DebugCommand.Continue, TestContext.Current.CancellationToken), TestContext.Current.CancellationToken);
        await Task.Delay(50, TestContext.Current.CancellationToken);
        var outcome = await session.StopAsync();
        continued.SetResult(Rows(new string?[] { null, null, null }));

        Assert.True(outcome.Confirmed);
        Assert.True(rig.Target.Cancels > 0);
        Assert.Equal(0, rig.Proxy.Cancels);
        Assert.Equal(PostgreSqlDebugProtocol.StoppedMessage, Assert.IsType<DebugStop.Failed>(await step.WaitAsync(TimeSpan.FromSeconds(5), TestContext.Current.CancellationToken)).Message);
    }

    [Fact]
    public async Task ATargetThatNeverEndsIsGivenUpAndNamedWithTheSqlThatEndsIt()
    {
        var rig = new Rig { Steps = sql => sql.Contains("pldbg_abort_target", StringComparison.Ordinal) ? Task.FromResult(Rows(["t"])) : null };
        await using var session = await rig.StartAsync(Request(), budget: TimeSpan.FromMilliseconds(300));
        await session.FirstStopAsync(TestContext.Current.CancellationToken);

        var outcome = await session.StopAsync();

        Assert.False(outcome.Confirmed);
        Assert.Equal(PostgreSqlDebugProtocol.AbandonedMessage, outcome.Message);
        Assert.Contains("Server process 4242", outcome.Detail, StringComparison.Ordinal);
        Assert.Contains("pldbg_attach_to_port(7)", outcome.Detail, StringComparison.Ordinal);
    }

    [Fact]
    public async Task ACallThatEndsBeforeEnteringTheRoutineFailsTheStartAndClosesBothConnections()
    {
        var rig = new Rig();
        rig.Target.Call = _ => Task.FromException<ResultSet>(new PostgreSqlDebugServerException("22P02", "invalid input syntax for type numeric: \"ten\""));

        var error = await Assert.ThrowsAsync<RoutineDebugException>(() => rig.StartAsync(Request()));

        Assert.Equal("invalid input syntax for type numeric: \"ten\"", error.Message);
        Assert.True(rig.Target.Disposed);
        Assert.True(rig.Proxy.Disposed);
    }

    [Fact]
    public async Task ARoutineThatCannotBeDebuggedIsRefusedBeforeTheTargetRunsAnything()
    {
        var rig = new Rig { Steps = sql => sql.Contains("current_database()", StringComparison.Ordinal) ? Task.FromResult(Rows(PostgreSqlDebugProtocolTests.RoutineRow(language: "sql"))) : null };

        await Assert.ThrowsAsync<RoutineDebugException>(() => rig.StartAsync(Request()));

        Assert.DoesNotContain(rig.Target.Sent, s => s.Contains("pldbg_oid_debug", StringComparison.Ordinal));
        Assert.True(rig.Target.Disposed);
    }

    [Fact]
    public async Task OtherNoticesBecomeOutputAndTheOutputEndsWithTheCall()
    {
        var rig = new Rig();
        rig.Target.Call = async call =>
        {
            rig.Target.RaiseNotice("total=11");
            rig.Target.RaiseNotice("PLDBGBREAK:7");
            return await rig.CallEnd.Task;
        };
        await using var session = await rig.StartAsync(Request());
        await session.FirstStopAsync(TestContext.Current.CancellationToken);

        rig.CallEnd.SetResult(Eleven);
        var lines = new List<string>();
        await foreach (var line in session.Output.ReadAllAsync(TestContext.Current.CancellationToken))
        {
            lines.Add(line);
        }

        Assert.Equal(["NOTICE: total=11"], lines);
    }

    [Fact]
    public async Task ACancelledStartAfterTheAnnouncementAttachesAndAborts()
    {
        var rig = new Rig();
        using var cancellation = new CancellationTokenSource();
        rig.Target.Call = async call =>
        {
            await cancellation.CancelAsync();
            rig.Target.RaiseNotice("PLDBGBREAK:7");
            return await rig.CallEnd.Task;
        };

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => rig.StartUntilAsync(Request(), null, cancellation.Token));

        // The proxy never attached, so it is the one that attaches now and aborts; the target ignores a cancel in accept().
        Assert.Contains(rig.Proxy.Sent, s => s.Contains("pldbg_attach_to_port(7)", StringComparison.Ordinal));
        Assert.Contains(rig.Proxy.Sent, s => s.Contains("pldbg_abort_target(1)", StringComparison.Ordinal));
        Assert.Empty(rig.Opened);
        Assert.True(rig.Target.Disposed && rig.Proxy.Disposed);
    }
}

/// <summary>A connection that answers each statement through <see cref="Respond"/>, one at a time as a real one does, and records it.</summary>
internal sealed class ScriptedPgConnection : IPostgreSqlDebugConnection
{
    private readonly SemaphoreSlim _gate = new(1, 1);

    public event Action<PostgreSqlDebugNotice>? Notice;

    public string Name { get; init; } = string.Empty;

    public Func<string, IReadOnlyList<string?>?, Task<IReadOnlyList<IReadOnlyList<string?>>>> Respond { get; set; } =
        (_, _) => Task.FromResult<IReadOnlyList<IReadOnlyList<string?>>>([]);

    public Func<PostgreSqlDebugCall, Task<ResultSet>> Call { get; set; } = _ => Task.FromResult(new ResultSet([], []));

    public Action? OnCancel { get; set; }

    public ConcurrentQueue<string> Sent { get; } = new();

    public ConcurrentQueue<IReadOnlyList<string?>> Parameters { get; } = new();

    public int ServerVersion { get; set; } = 170_002;

    public int? ProcessId { get; set; } = 4242;

    public bool HasLostConnection { get; set; }

    public int Cancels;

    public bool Disposed { get; private set; }

    public void RaiseNotice(string text) => Notice?.Invoke(new PostgreSqlDebugNotice("NOTICE", text));

    public async Task<IReadOnlyList<IReadOnlyList<string?>>> QueryAsync(string sql, IReadOnlyList<string?>? parameters = null, CancellationToken cancellationToken = default)
    {
        Sent.Enqueue(sql);
        await _gate.WaitAsync(CancellationToken.None);
        try
        {
            await Task.Yield();
            return await Respond(sql, parameters);
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task<ResultSet> CallAsync(PostgreSqlDebugCall call, CancellationToken cancellationToken = default)
    {
        Sent.Enqueue(call.Sql);
        Parameters.Enqueue(call.Parameters);
        await Task.Yield();
        return await Call(call);
    }

    public void Cancel()
    {
        Interlocked.Increment(ref Cancels);
        OnCancel?.Invoke();
    }

    public ValueTask DisposeAsync()
    {
        Disposed = true;
        return ValueTask.CompletedTask;
    }
}
