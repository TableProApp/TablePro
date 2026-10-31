using TablePro.Core.Debugging;
using TablePro.Core.Drivers;
using TablePro.Core.Results;
using TablePro.Core.Schema;

namespace TablePro.Core.Tests.Debugging;

public sealed class RoutineDebugControllerTests
{
    private static readonly DebugEntryPoint Entry = new("16384", "add_tax(p_amount numeric)", [new DebugParameter("p_amount", "numeric", DebugParameterMode.Input, false)]);

    private static RoutineDebugPlan Plan(RoutineDebugPreparation? preparation = null) =>
        new(new RoutineDebugTarget("16384", new ObjectName("public", "add_tax"), "add_tax", "Function"), [Entry], true, preparation);

    private static RoutineDebugController Controller(
        FakeDebugger debugger,
        RoutineDebugPreparation? preparation = null,
        Func<RoutineDebugPreparation, CancellationToken, Task<bool>>? confirm = null,
        TimeSpan? stopLimit = null) =>
        new(
            debugger,
            Plan(preparation),
            new RoutineDebugStartChoice(Entry, [new DebugArgument("p_amount", DebugArgumentValue.FromText("10"))]),
            confirm ?? ((_, _) => Task.FromResult(true)),
            stopLimit ?? TimeSpan.FromSeconds(2));

    private static FakeDebugger Starting(FakeSession session) => new((_, _) => Task.FromResult<IRoutineDebugSession>(session));

    private static async Task PausedAndLoadedAsync(RoutineDebugController controller) =>
        await Eventually.TrueAsync(() => controller.State == DebugRunState.Paused && controller.DisplayedFrameLevel is not null, "the pause loaded");

    [Fact]
    public async Task TheFirstStopPausesAtTheReportedLineAndLoadsSourceStackAndVariables()
    {
        var session = new FakeSession();
        using var controller = Controller(Starting(session));

        controller.Start();
        await PausedAndLoadedAsync(controller);

        Assert.Equal(3, controller.PausedLocation!.Line);
        Assert.Equal(3, controller.ExecutionLine);
        Assert.Equal("Paused at line 3 in add_tax(numeric)", controller.StatusText);
        Assert.Contains("x := 1;", controller.DisplayedSource, StringComparison.Ordinal);
        Assert.Equal(2, controller.Frames.Count);
        Assert.Equal("p_amount", Assert.Single(controller.Variables).Name);
        Assert.Equal(["first", "source 16384", "stack", "variables 0"], session.Calls);
        Assert.True(controller.CanPerform(DebugCommand.StepOver));
        Assert.False(controller.CanPerform(DebugCommand.StepOut));
    }

    [Fact]
    public async Task TheStartCarriesTheChosenEntryPointAndArguments()
    {
        var debugger = Starting(new FakeSession());
        using var controller = Controller(debugger);

        controller.Start();
        await PausedAndLoadedAsync(controller);

        var request = Assert.Single(debugger.Requests);
        Assert.Equal("16384", request.EntryPoint.Identity);
        Assert.Equal(DebugArgumentValue.FromText("10"), Assert.Single(request.Arguments).Value);
    }

    [Fact]
    public async Task StopWhilePausedEndsTheTargetOnceAndClosesTheSession()
    {
        var session = new FakeSession();
        using var controller = Controller(Starting(session));
        controller.Start();
        await PausedAndLoadedAsync(controller);

        controller.Stop();
        controller.Stop();
        await controller.WaitUntilEndedAsync().WaitAsync(TimeSpan.FromSeconds(5), TestContext.Current.CancellationToken);

        Assert.Equal(DebugRunState.Stopped, controller.State);
        Assert.Equal("Stopped", controller.StatusText);
        Assert.Equal(1, session.StopCalls);
        Assert.Equal(1, session.DisposeCalls);
        Assert.False(controller.CanStop);
    }

    [Fact]
    public async Task StopWhileAStepRunsEndsTheTargetOnceAndTheStepsAnswerBecomesTheStatus()
    {
        var session = new FakeSession();
        var step = new TaskCompletionSource<DebugStop>();
        session.Perform = _ => step.Task;
        session.Stop = () =>
        {
            step.TrySetResult(new DebugStop.Failed("The routine was stopped, and its uncommitted changes were rolled back.", null));
            return Task.FromResult(DebugStopOutcome.Ended);
        };
        using var controller = Controller(Starting(session));
        controller.Start();
        await PausedAndLoadedAsync(controller);

        controller.Perform(DebugCommand.Continue);
        await Eventually.TrueAsync(() => session.Calls.Contains("perform Continue"), "the step was sent");
        Assert.False(controller.CanPerform(DebugCommand.StepOver));
        controller.Stop();
        await controller.WaitUntilEndedAsync().WaitAsync(TimeSpan.FromSeconds(5), TestContext.Current.CancellationToken);
        await Eventually.TrueAsync(() => controller.Message is not null, "the step's answer arrived");

        Assert.Equal(DebugRunState.Stopped, controller.State);
        Assert.Equal("The routine was stopped, and its uncommitted changes were rolled back.", controller.StatusText);
        Assert.Equal(1, session.StopCalls);
    }

    [Fact]
    public async Task AStepThatFinishesAsTheStopArrivesSaysTheRoutineFinishedFirst()
    {
        var session = new FakeSession();
        var step = new TaskCompletionSource<DebugStop>();
        session.Perform = _ => step.Task;
        session.Stop = () =>
        {
            step.TrySetResult(new DebugStop.Finished(null));
            return Task.FromResult(DebugStopOutcome.Ended);
        };
        using var controller = Controller(Starting(session));
        controller.Start();
        await PausedAndLoadedAsync(controller);

        controller.Perform(DebugCommand.Continue);
        await Eventually.TrueAsync(() => session.Calls.Contains("perform Continue"), "the step was sent");
        controller.Stop();
        await controller.WaitUntilEndedAsync().WaitAsync(TimeSpan.FromSeconds(5), TestContext.Current.CancellationToken);
        await Eventually.TrueAsync(() => controller.Message is not null, "the step's answer arrived");

        Assert.Equal(RoutineDebugController.FinishedBeforeStop, controller.StatusText);
    }

    [Fact]
    public async Task AStopTheSessionCannotConfirmShowsItsWords()
    {
        var session = new FakeSession { Stop = () => Task.FromResult(DebugStopOutcome.Unconfirmed("The routine couldn't be stopped on the server.", "Server process 4242 may still be running.")) };
        using var controller = Controller(Starting(session));
        controller.Start();
        await PausedAndLoadedAsync(controller);

        controller.Stop();
        await controller.WaitUntilEndedAsync().WaitAsync(TimeSpan.FromSeconds(5), TestContext.Current.CancellationToken);

        Assert.Equal("The routine couldn't be stopped on the server.\nServer process 4242 may still be running.", controller.StatusText);
    }

    [Fact]
    public async Task ATargetWhoseStopNeverReturnsLosesItsConnectionsAtTheLimit()
    {
        var session = new FakeSession { Stop = () => new TaskCompletionSource<DebugStopOutcome>().Task };
        using var controller = Controller(Starting(session), stopLimit: TimeSpan.FromMilliseconds(200));
        controller.Start();
        await PausedAndLoadedAsync(controller);

        controller.Stop();
        await controller.WaitUntilEndedAsync().WaitAsync(TimeSpan.FromSeconds(5), TestContext.Current.CancellationToken);

        Assert.Equal(RoutineDebugController.StopNotConfirmed, controller.StatusText);
        Assert.Equal(1, session.DisposeCalls);
    }

    [Fact]
    public async Task StopWhileStartingCancelsTheStartAndEndsStopped()
    {
        var debugger = new FakeDebugger(async (_, token) =>
        {
            await Task.Delay(Timeout.Infinite, token);
            throw new InvalidOperationException("unreachable");
        });
        using var controller = Controller(debugger);
        controller.Start();
        await Eventually.TrueAsync(() => controller.State == DebugRunState.Starting, "the start began");

        controller.Stop();
        await controller.WaitUntilEndedAsync().WaitAsync(TimeSpan.FromSeconds(5), TestContext.Current.CancellationToken);

        Assert.Equal(DebugRunState.Stopped, controller.State);
        Assert.Equal("Stopped", controller.StatusText);
    }

    [Fact]
    public async Task ACancelledStartThatCannotConfirmItsTargetEndedShowsWhy()
    {
        var debugger = new FakeDebugger(async (_, token) =>
        {
            try
            {
                await Task.Delay(Timeout.Infinite, token);
            }
            catch (OperationCanceledException)
            {
                throw new RoutineDebugException("The routine couldn't be stopped on the server.", "Server process 7 may still be waiting for a debugger.");
            }

            throw new InvalidOperationException("unreachable");
        });
        using var controller = Controller(debugger);
        controller.Start();
        await Eventually.TrueAsync(() => controller.State == DebugRunState.Starting, "the start began");

        controller.Stop();
        await controller.WaitUntilEndedAsync().WaitAsync(TimeSpan.FromSeconds(5), TestContext.Current.CancellationToken);

        Assert.StartsWith("The routine couldn't be stopped on the server.", controller.StatusText, StringComparison.Ordinal);
    }

    [Fact]
    public async Task AStartThatIgnoresItsCancellationIsGivenUpAtTheLimitAndALateSessionIsStillEnded()
    {
        var session = new FakeSession();
        var late = new TaskCompletionSource<IRoutineDebugSession>();
        using var controller = Controller(new FakeDebugger((_, _) => late.Task), stopLimit: TimeSpan.FromMilliseconds(200));
        controller.Start();
        await Eventually.TrueAsync(() => controller.State == DebugRunState.Starting, "the start began");

        controller.Stop();
        await controller.WaitUntilEndedAsync().WaitAsync(TimeSpan.FromSeconds(5), TestContext.Current.CancellationToken);
        Assert.Equal(RoutineDebugController.StopNotConfirmed, controller.StatusText);

        late.SetResult(session);
        await Eventually.TrueAsync(() => session.DisposeCalls == 1, "the late session was closed");
        Assert.Equal(1, session.StopCalls);
    }

    [Fact]
    public async Task AStepThatFailsEndsTheTargetBeforeItsConnectionsCloseAndSaysSoOnce()
    {
        var session = new FakeSession { Perform = _ => throw new RoutineDebugException("The debugger couldn't finish this step.", "ORA-03113") };
        using var controller = Controller(Starting(session));
        controller.Start();
        await PausedAndLoadedAsync(controller);

        controller.Perform(DebugCommand.StepOver);
        await controller.WaitUntilEndedAsync().WaitAsync(TimeSpan.FromSeconds(5), TestContext.Current.CancellationToken);

        Assert.Equal(DebugRunState.Failed, controller.State);
        Assert.Equal("The debugger couldn't finish this step.\nORA-03113", controller.StatusText);
        Assert.Equal(1, session.StopCalls);
        Assert.Equal(1, session.DisposeCalls);
    }

    [Fact]
    public async Task ACommandTheSessionDoesNotSupportIsNeverSent()
    {
        var session = new FakeSession();
        using var controller = Controller(Starting(session));
        controller.Start();
        await PausedAndLoadedAsync(controller);

        controller.Perform(DebugCommand.StepOut);

        Assert.Equal(DebugRunState.Paused, controller.State);
        Assert.DoesNotContain("perform StepOut", session.Calls);
    }

    [Fact]
    public async Task AFinishedRoutineKeepsItsResultAndOutputThatArrivesAsItEnds()
    {
        var session = new FakeSession();
        var result = new ResultSet([new ResultColumn("add_tax", "numeric", typeof(decimal))], [[11m]]);
        session.Perform = _ =>
        {
            session.OutputChannel.Writer.TryWrite("NOTICE: total=11");
            session.OutputChannel.Writer.TryComplete();
            return Task.FromResult<DebugStop>(new DebugStop.Finished(result));
        };
        using var controller = Controller(Starting(session));
        controller.Start();
        await PausedAndLoadedAsync(controller);

        controller.Perform(DebugCommand.Continue);
        await controller.WaitUntilEndedAsync().WaitAsync(TimeSpan.FromSeconds(5), TestContext.Current.CancellationToken);

        Assert.Equal(DebugRunState.Finished, controller.State);
        Assert.Same(result, controller.Result);
        Assert.Equal(["NOTICE: total=11"], controller.OutputLines);
        Assert.Equal(0, session.StopCalls);
    }

    [Fact]
    public async Task DecliningThePreparationStartsNothingAndAsksForTheTabToClose()
    {
        var debugger = Starting(new FakeSession());
        var preparation = new RoutineDebugPreparation("PKG isn't compiled for debugging.", null, "Compile for Debug", ["ALTER PACKAGE \"P\".\"PKG\" COMPILE BODY"]);
        using var controller = Controller(debugger, preparation, (_, _) => Task.FromResult(false));
        var declined = false;
        controller.Declined += (_, _) => declined = true;

        controller.Start();
        await controller.WaitUntilEndedAsync().WaitAsync(TimeSpan.FromSeconds(5), TestContext.Current.CancellationToken);

        Assert.True(declined);
        Assert.Equal(DebugRunState.Stopped, controller.State);
        Assert.Empty(debugger.Requests);
        Assert.Equal(0, debugger.Preparations);
    }

    [Fact]
    public async Task AConfirmedPreparationRunsBeforeTheStart()
    {
        var debugger = Starting(new FakeSession());
        var preparation = new RoutineDebugPreparation("PKG isn't compiled for debugging.", null, "Compile for Debug", ["ALTER PACKAGE \"P\".\"PKG\" COMPILE BODY"]);
        using var controller = Controller(debugger, preparation);

        controller.Start();
        await PausedAndLoadedAsync(controller);

        Assert.Equal(1, debugger.Preparations);
        Assert.Single(debugger.Requests);
    }

    [Fact]
    public async Task StoppingWhileThePreparationQuestionIsUpWithdrawsItAndEndsStopped()
    {
        var debugger = Starting(new FakeSession());
        var preparation = new RoutineDebugPreparation("PKG isn't compiled for debugging.", null, "Compile for Debug", ["ALTER PACKAGE"]);
        var asked = false;
        using var controller = Controller(debugger, preparation, async (_, token) =>
        {
            asked = true;
            await Task.Delay(Timeout.Infinite, token);
            return true;
        });
        var declined = false;
        controller.Declined += (_, _) => declined = true;
        controller.Start();
        await Eventually.TrueAsync(() => asked, "the question was asked");

        controller.Stop();
        await controller.WaitUntilEndedAsync().WaitAsync(TimeSpan.FromSeconds(5), TestContext.Current.CancellationToken);

        Assert.Equal(DebugRunState.Stopped, controller.State);
        Assert.False(declined);
        Assert.Empty(debugger.Requests);
    }

    [Fact]
    public async Task AFailedPreparationFailsTheRunWithItsMessage()
    {
        var debugger = Starting(new FakeSession());
        debugger.Prepare = (_, _) => throw new InvalidOperationException("ORA-01031: insufficient privileges");
        var preparation = new RoutineDebugPreparation("PKG isn't compiled for debugging.", null, "Compile for Debug", ["ALTER PACKAGE"]);
        using var controller = Controller(debugger, preparation);

        controller.Start();
        await controller.WaitUntilEndedAsync().WaitAsync(TimeSpan.FromSeconds(5), TestContext.Current.CancellationToken);

        Assert.Equal(DebugRunState.Failed, controller.State);
        Assert.Equal("ORA-01031: insufficient privileges", controller.StatusText);
        Assert.Empty(debugger.Requests);
    }

    [Fact]
    public async Task ABreakpointToggledWhilePausedIsPlacedWhereTheEngineMovedIt()
    {
        var session = new FakeSession { Set = b => Task.FromResult<DebugBreakpoint?>(b with { Line = b.Line + 1 }) };
        using var controller = Controller(Starting(session));
        controller.Start();
        await PausedAndLoadedAsync(controller);

        controller.ToggleBreakpoint(3);
        await Eventually.TrueAsync(() => controller.DisplayedBreakpointLines.Contains(4), "the marker moved to the placed line");

        Assert.DoesNotContain(3, controller.DisplayedBreakpointLines);
        Assert.Contains("set 3", session.Calls);
    }

    [Fact]
    public async Task ABreakpointTheEngineCannotPlaceDropsItsMarker()
    {
        var session = new FakeSession { Set = _ => Task.FromResult<DebugBreakpoint?>(null) };
        using var controller = Controller(Starting(session));
        controller.Start();
        await PausedAndLoadedAsync(controller);

        controller.ToggleBreakpoint(2);
        await Eventually.TrueAsync(() => session.Calls.Contains("set 2"), "the placement was asked");
        await Eventually.TrueAsync(() => controller.DisplayedBreakpointLines.Count == 0, "the marker dropped");
    }

    [Fact]
    public async Task ABreakpointRemovedAfterItWasPlacedComesOffTheServer()
    {
        var session = new FakeSession();
        using var controller = Controller(Starting(session));
        controller.Start();
        await PausedAndLoadedAsync(controller);

        controller.ToggleBreakpoint(4);
        await Eventually.TrueAsync(() => session.Calls.Contains("set 4"), "the breakpoint was placed");
        controller.ToggleBreakpoint(4);
        await Eventually.TrueAsync(() => session.Calls.Contains("remove 4"), "the breakpoint was removed");

        Assert.False(controller.HasBreakpoints);
    }

    [Fact]
    public async Task ABreakpointChangedWhileRunningReachesTheSessionAtTheNextPauseBeforeTheStep()
    {
        var session = new FakeSession();
        var step = new TaskCompletionSource<DebugStop>();
        using var controller = Controller(Starting(session));
        controller.Start();
        await PausedAndLoadedAsync(controller);

        session.Perform = _ => step.Task;
        controller.Perform(DebugCommand.Continue);
        await Eventually.TrueAsync(() => session.Calls.Contains("perform Continue"), "the step was sent");
        controller.ToggleBreakpoint(4);
        Assert.DoesNotContain("set 4", session.Calls);

        step.SetResult(new DebugStop.Paused(new DebugLocation(FakeSession.Unit, 2)));
        await Eventually.TrueAsync(() => session.Calls.Contains("set 4"), "the breakpoint reached the session");
        Assert.Contains(4, controller.DisplayedBreakpointLines);
    }

    [Fact]
    public async Task ToggleBreakpointActsOnTheCursorLineOnlyWhenItCan()
    {
        var session = new FakeSession();
        using var controller = Controller(Starting(session));
        Assert.False(controller.CanToggleBreakpoint);
        controller.Start();
        await PausedAndLoadedAsync(controller);
        Assert.False(controller.CanToggleBreakpoint);

        controller.CursorLine = 2;
        Assert.True(controller.CanToggleBreakpoint);
        controller.ToggleBreakpointAtCursor();
        Assert.Contains(2, controller.DisplayedBreakpointLines);
        Assert.True(controller.CanRemoveAllBreakpoints);

        controller.RemoveAllBreakpoints();
        Assert.False(controller.HasBreakpoints);
        Assert.False(controller.CanRemoveAllBreakpoints);
    }

    [Fact]
    public async Task ChoosingAFrameShowsItsOwnVariablesAndLine()
    {
        var session = new FakeSession();
        using var controller = Controller(Starting(session));
        controller.Start();
        await PausedAndLoadedAsync(controller);

        controller.SelectFrame(1);
        await Eventually.TrueAsync(() => controller.DisplayedFrameLevel == 1, "the frame loaded");

        Assert.Equal("p_n", Assert.Single(controller.Variables).Name);
        Assert.Equal(9, controller.ExecutionLine);
    }

    [Fact]
    public async Task ANewPauseNeverShowsTheLastPausesVariables()
    {
        var session = new FakeSession();
        using var controller = Controller(Starting(session));
        controller.Start();
        await PausedAndLoadedAsync(controller);
        Assert.NotEmpty(controller.Variables);

        session.Variables = _ => throw new RoutineDebugException("The routine isn't paused.");
        controller.Perform(DebugCommand.StepOver);
        await Eventually.TrueAsync(() => controller.InspectionError is not null, "the read failed");

        Assert.Empty(controller.Variables);
        Assert.Equal(4, controller.PausedLocation!.Line);
    }

    [Fact]
    public async Task AStopThatLandsBeforeTheRunBeginsOpensNothing()
    {
        var debugger = Starting(new FakeSession());
        using var controller = Controller(debugger);

        controller.Stop();
        await controller.WaitUntilEndedAsync().WaitAsync(TimeSpan.FromSeconds(5), TestContext.Current.CancellationToken);
        controller.Start();

        Assert.Equal(DebugRunState.Stopped, controller.State);
        Assert.Empty(debugger.Requests);
    }

    [Fact]
    public async Task OutputLinesFromTheSessionReachTheController()
    {
        var session = new FakeSession();
        using var controller = Controller(Starting(session));
        controller.Start();
        await PausedAndLoadedAsync(controller);

        session.OutputChannel.Writer.TryWrite("NOTICE: one");
        session.OutputChannel.Writer.TryWrite("NOTICE: two");

        await Eventually.TrueAsync(() => controller.OutputLines.Count == 2, "the output arrived");
        Assert.Equal(["NOTICE: one", "NOTICE: two"], controller.OutputLines);
    }
}
