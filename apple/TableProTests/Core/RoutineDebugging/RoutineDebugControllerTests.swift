//
//  RoutineDebugControllerTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import TableProTestSupport
import Testing

@MainActor
struct RoutineDebugControllerTests {
    @Test("The first stop pauses at the reported line and loads the source, stack and variables")
    func firstStopPausesAndInspects() async throws {
        let session = FakeDebugSession(firstStopLine: 2)
        let (controller, _) = RoutineDebugFixtures.controller(session: session)

        controller.start()
        try await waitUntil { controller.state.pausedLocation != nil && !controller.variables.isEmpty }

        #expect(controller.state.pausedLocation?.line == 2)
        #expect(controller.executionLine == 2)
        #expect(controller.displayedUnit == FakeDebugSession.unit)
        #expect(controller.displayedSource == FakeDebugSession.source)
        #expect(controller.frames.count == 1)
        #expect(controller.variables.map { $0.name } == ["total", "note"])
        #expect(session.sourceReadCount == 1)
        #expect(session.stackReadCount == 1)
        #expect(session.variableReadLevels == [0])
        #expect(controller.statusText == String(format: String(localized: "Paused at line %d in %@"), 2, FakeDebugSession.unit.displayName))
    }

    @Test("Stop while paused ends the target once and closes every driver it took")
    func stopWhilePaused() async throws {
        let session = FakeDebugSession()
        let drivers = DebugDriverLog()
        let (controller, _) = RoutineDebugFixtures.controller(session: session, drivers: drivers)
        controller.start()
        try await waitUntil { controller.state.pausedLocation != nil }

        controller.stop()
        controller.stop()
        await controller.waitUntilEnded()

        #expect(session.stopCount == 1)
        #expect(drivers.openedCount == 2)
        #expect(drivers.closedCount == 2)
        guard case .stopped = controller.state else {
            Issue.record("expected stopped, got \(controller.state)")
            return
        }
        #expect(controller.statusText == String(localized: "Stopped"))
        #expect(!controller.canStop)
    }

    @Test("Stop while a step runs ends the target once, and the step's late answer does not reopen it")
    func stopWhileRunning() async throws {
        let session = FakeDebugSession(performBlocksUntilStop: true)
        let drivers = DebugDriverLog()
        let (controller, _) = RoutineDebugFixtures.controller(session: session, drivers: drivers)
        controller.start()
        try await waitUntil { controller.state.pausedLocation != nil }

        controller.perform(.continueExecution)
        try await waitUntil { session.performedCommands == [.continueExecution] }
        controller.stop()
        await controller.waitUntilEnded()

        #expect(session.stopCount == 1)
        #expect(drivers.closedCount == drivers.openedCount)
        guard case .stopped = controller.state else {
            Issue.record("expected stopped, got \(controller.state)")
            return
        }
    }

    @Test("Stop while the debugger is still starting cancels the start, closes its drivers and ends stopped")
    func stopWhileStartingCancelsTheStart() async throws {
        let session = FakeDebugSession()
        let drivers = DebugDriverLog()
        let (controller, debugger) = RoutineDebugFixtures.controller(
            session: session,
            drivers: drivers,
            startBehavior: .untilCancelled
        )
        controller.start()
        try await waitUntil { drivers.openedCount == 2 }

        controller.stop()
        try await waitUntil { controller.hasEnded }

        #expect(debugger.startWasCancelled)
        #expect(drivers.closedCount == 2)
        #expect(session.stopCount == 0)
        guard case .stopped = controller.state else {
            Issue.record("expected stopped, got \(controller.state)")
            return
        }
    }

    @Test("A cancelled start that cannot confirm its target ended shows why")
    func unconfirmedCancelledStartBecomesTheStatus() async throws {
        let drivers = DebugDriverLog()
        let (controller, debugger) = RoutineDebugFixtures.controller(
            session: FakeDebugSession(),
            drivers: drivers,
            startBehavior: .untilCancelledThenThrowing(FakeDebugError(message: "Server process 4242 may still be running."))
        )
        controller.start()
        try await waitUntil { drivers.openedCount == 2 }

        controller.stop()
        try await waitUntil { controller.hasEnded }

        #expect(debugger.startWasCancelled)
        #expect(controller.statusText == "Server process 4242 may still be running.")
    }

    @Test("A step that finishes as the stop arrives says the routine finished first")
    func finishedAnswerToAStopBecomesTheStatus() async throws {
        let session = FakeDebugSession(performBlocksUntilStop: true, stopAnswer: .finished(nil))
        let (controller, _) = RoutineDebugFixtures.controller(session: session)
        controller.start()
        try await waitUntil { controller.state.pausedLocation != nil }

        controller.perform(.continueExecution)
        try await waitUntil { session.performedCommands == [.continueExecution] }
        controller.stop()
        try await waitUntil { controller.hasEnded && controller.statusText != String(localized: "Stopped") }

        #expect(controller.statusText == String(localized: "The routine finished before the stop reached it."))
    }

    @Test("A start that ignores its cancellation loses its drivers at the limit, and a late session is still ended")
    func startIgnoringCancellationIsCapped() async throws {
        let late = AsyncGate()
        let session = FakeDebugSession()
        let drivers = DebugDriverLog()
        let (controller, _) = RoutineDebugFixtures.controller(
            session: session,
            drivers: drivers,
            startBehavior: .ignoringCancellation(late),
            cancelLimit: .milliseconds(50)
        )
        controller.start()
        try await waitUntil { drivers.openedCount == 2 }

        controller.stop()
        try await waitUntil { controller.hasEnded }
        #expect(drivers.closedCount == 2)
        guard case .stopped = controller.state else {
            Issue.record("expected stopped, got \(controller.state)")
            return
        }
        #expect(controller.statusText == RoutineDebugController.stopNotConfirmed)

        await late.open()
        try await waitUntil { session.stopCount == 1 }
    }

    @Test("When the plugin answers a stop with its own words, the status says them instead of Stopped")
    func stopAnswerBecomesTheStatus() async throws {
        let session = FakeDebugSession(
            performBlocksUntilStop: true,
            stopAnswer: .failed(message: "The routine is still running on the server.", detail: nil)
        )
        let (controller, _) = RoutineDebugFixtures.controller(session: session)
        controller.start()
        try await waitUntil { controller.state.pausedLocation != nil }

        controller.perform(.continueExecution)
        try await waitUntil { session.performedCommands == [.continueExecution] }
        controller.stop()
        try await waitUntil { controller.hasEnded && controller.statusText != String(localized: "Stopped") }

        #expect(controller.statusText == "The routine is still running on the server.")
        guard case .stopped = controller.state else {
            Issue.record("expected stopped, got \(controller.state)")
            return
        }
    }

    @Test("A stop the plugin cannot confirm shows its words, whether or not a step was waiting", arguments: [false, true])
    func unconfirmedStopBecomesTheStatus(stepWaiting: Bool) async throws {
        let session = FakeDebugSession(
            performBlocksUntilStop: stepWaiting,
            stopAnswer: .failed(message: "Cancelled.", detail: nil),
            stopOutcome: .unconfirmed(message: "Server process 4242 may still be running.", detail: "End it with pg_terminate_backend(4242).")
        )
        let (controller, _) = RoutineDebugFixtures.controller(session: session)
        controller.start()
        try await waitUntil { controller.state.pausedLocation != nil && !controller.variables.isEmpty }
        if stepWaiting {
            controller.perform(.continueExecution)
            try await waitUntil { session.performedCommands == [.continueExecution] }
        }

        controller.stop()
        try await waitUntil { controller.hasEnded }

        #expect(controller.statusText == "Server process 4242 may still be running.\nEnd it with pg_terminate_backend(4242).")
    }

    @Test("A command is refused while a step runs")
    func performRefusedWhileRunning() async throws {
        let session = FakeDebugSession(performBlocksUntilStop: true)
        let (controller, _) = RoutineDebugFixtures.controller(session: session)
        controller.start()
        try await waitUntil { controller.state.pausedLocation != nil }

        controller.perform(.stepOver)
        #expect(!controller.canPerform(.stepOver))
        controller.perform(.stepOver)
        controller.perform(.continueExecution)
        try await waitUntil { !session.performedCommands.isEmpty }

        #expect(session.performedCommands == [.stepOver])
        controller.stop()
        await controller.waitUntilEnded()
    }

    @Test("A command the session does not support is never sent")
    func unsupportedCommandIsRefused() async throws {
        let session = FakeDebugSession(supportedCommands: [.continueExecution, .stepOver, .stepInto])
        let (controller, _) = RoutineDebugFixtures.controller(session: session)
        controller.start()
        try await waitUntil { controller.state.pausedLocation != nil }

        #expect(!controller.canPerform(.stepOut))
        controller.perform(.stepOut)

        #expect(session.performedCommands.isEmpty)
        controller.stop()
        await controller.waitUntilEnded()
    }

    @Test("A stop that lands before the run begins asks nothing and opens nothing")
    func stopBeforeTheRunBegins() async throws {
        let gate = WaitingGate()
        let drivers = DebugDriverLog()
        let (controller, _) = RoutineDebugFixtures.controller(drivers: drivers, gate: gate)
        controller.start()
        controller.stop()
        try await waitUntil { controller.hasEnded }

        #expect(gate.askedCount == 0)
        #expect(drivers.openedCount == 0)
        guard case .stopped = controller.state else {
            Issue.record("expected stopped, got \(controller.state)")
            return
        }
    }

    @Test("A step that fails with its target left running stops the session before its drivers close, and says so once")
    func failedStepStopsTheSession() async throws {
        let words = "Server process 4242 may still be running."
        let session = FakeDebugSession(
            stopOutcome: .unconfirmed(message: words, detail: nil),
            performAnswer: .failed(message: words, detail: nil)
        )
        let (controller, _) = RoutineDebugFixtures.controller(session: session)
        controller.start()
        try await waitUntil { controller.state.pausedLocation != nil }

        controller.perform(.continueExecution)
        try await waitUntil { controller.hasEnded }

        #expect(session.stopCount == 1)
        #expect(controller.unconfirmedStop == words)
        #expect(controller.statusText == words)
    }

    @Test("Stop while the gate is still asking withdraws its prompt and ends the run Stopped, opening nothing")
    func stopWhileTheGateAsks() async throws {
        let gate = WaitingGate()
        let drivers = DebugDriverLog()
        let (controller, debugger) = RoutineDebugFixtures.controller(drivers: drivers, gate: gate)
        var cancelled = false
        controller.onCancelled = { cancelled = true }
        controller.start()
        try await waitUntil { gate.askedCount == 1 }

        controller.stop()
        try await waitUntil { controller.hasEnded }

        #expect(gate.sawCancellation)
        #expect(!cancelled)
        #expect(debugger.startRequests.isEmpty)
        #expect(drivers.openedCount == 0)
        guard case .stopped = controller.state else {
            Issue.record("expected stopped, got \(controller.state)")
            return
        }
    }

    @Test("A gate that cannot be withdrawn is not waited on past the limit, and its late yes starts nothing")
    func gateIgnoringCancellationIsCapped() async throws {
        let answer = AsyncGate()
        let gate = WaitingGate(ignoringCancellationUntil: answer)
        let drivers = DebugDriverLog()
        let (controller, debugger) = RoutineDebugFixtures.controller(
            drivers: drivers,
            gate: gate,
            cancelLimit: .milliseconds(50)
        )
        controller.start()
        try await waitUntil { gate.askedCount == 1 }

        controller.stop()
        try await waitUntil { controller.hasEnded }
        await answer.open()

        #expect(debugger.startRequests.isEmpty)
        #expect(drivers.openedCount == 0)
        guard case .stopped = controller.state else {
            Issue.record("expected stopped, got \(controller.state)")
            return
        }
    }

    @Test("A plan that may write is denied by a read-only gate, and no session opens")
    func readOnlyGateDeniesWritingPlan() async throws {
        let drivers = DebugDriverLog()
        let (controller, debugger) = RoutineDebugFixtures.controller(
            drivers: drivers,
            plan: RoutineDebugFixtures.plan(mayWrite: true),
            gate: AlwaysDenyGate(reason: "Read-Only connection")
        )

        controller.start()
        await controller.waitUntilEnded()

        guard case .failed(let message) = controller.state else {
            Issue.record("expected failed, got \(controller.state)")
            return
        }
        #expect(message == "Read-Only connection")
        #expect(debugger.startRequests.isEmpty)
        #expect(drivers.openedCount == 0)
    }

    @Test("The run asks the gate as a write when the plan may write, and as a read otherwise")
    func gateKindFollowsThePlan() async throws {
        let writing = RecordingGate()
        let (writer, _) = RoutineDebugFixtures.controller(plan: RoutineDebugFixtures.plan(mayWrite: true), gate: writing)
        writer.start()
        try await waitUntil { writer.state.pausedLocation != nil }
        let reading = RecordingGate()
        let (reader, _) = RoutineDebugFixtures.controller(plan: RoutineDebugFixtures.plan(mayWrite: false), gate: reading)
        reader.start()
        try await waitUntil { reader.state.pausedLocation != nil }

        #expect(writing.requests.map { $0.kind } == [.writeQuery])
        #expect(reading.requests.map { $0.kind } == [.readQuery])
        #expect(writing.requests.first?.caller == .userInterface)
        #expect(writing.requests.first?.operationDescription == String(localized: "Debug Routine"))
        writer.stop()
        reader.stop()
        await writer.waitUntilEnded()
        await reader.waitUntilEnded()
    }

    @Test("A preparation runs on a driver of its own, after the user confirms, through the gate as DDL")
    func preparationRunsOnItsOwnDriver() async throws {
        let drivers = DebugDriverLog()
        let gate = RecordingGate()
        let preparation = PluginDebugPreparation(
            message: "Compile for debugging?",
            informativeText: nil,
            actionTitle: "Compile for Debug",
            statements: ["ALTER PACKAGE p COMPILE BODY"]
        )
        let (controller, _) = RoutineDebugFixtures.controller(
            drivers: drivers,
            plan: RoutineDebugFixtures.plan(preparation: preparation),
            gate: gate
        )

        controller.start()
        try await waitUntil { controller.state.pausedLocation != nil }

        #expect(gate.requests.map { $0.kind } == [.readQuery, .schemaMutation])
        #expect(gate.requests.last?.sql == "ALTER PACKAGE p COMPILE BODY")
        #expect(drivers.openedCount == 3)
        #expect(drivers.closedCount == 1)
        controller.stop()
        await controller.waitUntilEnded()
        #expect(drivers.closedCount == 3)
    }

    @Test("Stop while the preparation statement runs cancels it, closes its driver, and the session never starts")
    func stopDuringPreparationStatement() async throws {
        let drivers = DebugDriverLog(statements: .untilCancelled)
        let (controller, debugger) = RoutineDebugFixtures.controller(
            drivers: drivers,
            plan: RoutineDebugFixtures.plan(preparation: Self.compile)
        )
        controller.start()
        try await waitUntil { drivers.executedCount == 1 }

        controller.stop()
        try await waitUntil { controller.hasEnded }

        #expect(drivers.closedCount == 1)
        #expect(debugger.startRequests.isEmpty)
        guard case .stopped = controller.state else {
            Issue.record("expected stopped, got \(controller.state)")
            return
        }
    }

    @Test("A preparation statement that ignores Stop is abandoned at the limit with its connection closed")
    func preparationStatementAbandonedAtTheLimit() async throws {
        let statement = AsyncGate()
        let drivers = DebugDriverLog(statements: .untilOpened(statement))
        let (controller, debugger) = RoutineDebugFixtures.controller(
            drivers: drivers,
            plan: RoutineDebugFixtures.plan(preparation: Self.compile),
            cancelLimit: .milliseconds(50)
        )
        controller.start()
        try await waitUntil { drivers.executedCount == 1 }

        controller.stop()
        try await waitUntil { controller.hasEnded }
        #expect(drivers.closedCount == 1)
        guard case .stopped = controller.state else {
            Issue.record("expected stopped, got \(controller.state)")
            return
        }

        await statement.open()
        #expect(debugger.startRequests.isEmpty)
        #expect(drivers.closedCount == 1)
        #expect(drivers.openedCount == 1)
    }

    private static let compile = PluginDebugPreparation(
        message: "Compile for debugging?",
        informativeText: nil,
        actionTitle: "Compile for Debug",
        statements: ["ALTER PACKAGE p COMPILE BODY"]
    )

    @Test("Declining the preparation starts nothing and asks for the tab to close")
    func declinedPreparationCancels() async throws {
        let drivers = DebugDriverLog()
        let preparation = PluginDebugPreparation(message: "m", informativeText: nil, actionTitle: "Compile", statements: ["X"])
        let (controller, debugger) = RoutineDebugFixtures.controller(
            drivers: drivers,
            plan: RoutineDebugFixtures.plan(preparation: preparation),
            confirmPreparation: { _ in false }
        )
        var cancelled = false
        controller.onCancelled = { cancelled = true }

        controller.start()
        await controller.waitUntilEnded()

        #expect(cancelled)
        #expect(debugger.startRequests.isEmpty)
        #expect(drivers.openedCount == 0)
    }

    @Test("A breakpoint set while running waits for the next pause, then shows where the engine placed it")
    func breakpointWhileRunningAppliesAtNextPause() async throws {
        let step = AsyncGate()
        let session = FakeDebugSession(firstStopLine: 2, placesBreakpoint: { $0 + 1 }, stepGate: step)
        let (controller, _) = RoutineDebugFixtures.controller(session: session)
        controller.start()
        try await waitUntil { controller.state.pausedLocation?.line == 2 && !controller.variables.isEmpty }

        controller.perform(.stepOver)
        await step.arrived(1)
        controller.toggleBreakpoint(atLine: 3)
        controller.toggleBreakpoint(atLine: 1)
        controller.toggleBreakpoint(atLine: 1)
        #expect(controller.displayedBreakpointLines == [3])
        #expect(session.placedBreakpointRequests.isEmpty)
        await step.open()
        try await waitUntil { controller.displayedBreakpointLines == [4] }

        #expect(session.placedBreakpointRequests == [PluginDebugBreakpoint(unitIdentity: FakeDebugSession.unit.identity, line: 3)])
        #expect(session.overlappingCallCount == 0)
        controller.stop()
        await controller.waitUntilEnded()
    }

    @Test("A step waits for the pause's reads to finish, so no session call overlaps another")
    func callsNeverOverlap() async throws {
        let session = FakeDebugSession()
        let (controller, _) = RoutineDebugFixtures.controller(session: session)
        controller.start()
        try await waitUntil { controller.state.pausedLocation != nil }

        controller.perform(.stepOver)
        try await waitUntil { controller.state.pausedLocation?.line == 3 }
        controller.toggleBreakpoint(atLine: 2)
        controller.perform(.stepInto)
        try await waitUntil { controller.state.pausedLocation?.line == 4 && !controller.variables.isEmpty }

        #expect(session.performedCommands == [.stepOver, .stepInto])
        #expect(session.overlappingCallCount == 0)
        controller.stop()
        await controller.waitUntilEnded()
    }

    @Test("A breakpoint removed while its placement is in flight comes off the server, where the engine put it")
    func removalDuringPlacementReachesTheServer() async throws {
        let placing = AsyncGate()
        let session = FakeDebugSession(placesBreakpoint: { $0 + 1 }, placeGate: placing)
        let (controller, _) = RoutineDebugFixtures.controller(session: session)
        controller.start()
        try await waitUntil { controller.state.pausedLocation != nil && !controller.variables.isEmpty }

        controller.toggleBreakpoint(atLine: 3)
        try await waitUntil { session.placedBreakpointRequests.count == 1 }
        controller.toggleBreakpoint(atLine: 3)
        #expect(controller.displayedBreakpointLines.isEmpty)
        await placing.open()
        try await waitUntil { !session.removedBreakpointRequests.isEmpty }

        #expect(session.removedBreakpointRequests == [PluginDebugBreakpoint(unitIdentity: FakeDebugSession.unit.identity, line: 4)])
        #expect(controller.displayedBreakpointLines.isEmpty)
        #expect(!controller.hasBreakpoints)
        controller.stop()
        await controller.waitUntilEnded()
    }

    @Test("Remove All while a placement is in flight also takes that breakpoint off the server")
    func removeAllDuringPlacementReachesTheServer() async throws {
        let placing = AsyncGate()
        let session = FakeDebugSession(placeGate: placing)
        let (controller, _) = RoutineDebugFixtures.controller(session: session)
        controller.start()
        try await waitUntil { controller.state.pausedLocation != nil && !controller.variables.isEmpty }

        controller.toggleBreakpoint(atLine: 3)
        try await waitUntil { session.placedBreakpointRequests.count == 1 }
        controller.removeAllBreakpoints()
        await placing.open()
        try await waitUntil { !session.removedBreakpointRequests.isEmpty }

        #expect(session.removedBreakpointRequests == [PluginDebugBreakpoint(unitIdentity: FakeDebugSession.unit.identity, line: 3)])
        #expect(!controller.hasBreakpoints)
        controller.stop()
        await controller.waitUntilEnded()
    }

    @Test("A breakpoint changed while the pause is still loading reaches the session before Continue does")
    func breakpointBeforeContinueWhileInspecting() async throws {
        let reads = AsyncGate()
        let session = FakeDebugSession(inspectGate: reads)
        let (controller, _) = RoutineDebugFixtures.controller(session: session)
        controller.start()
        try await waitUntil { session.sourceReadCount == 1 }

        controller.toggleBreakpoint(atLine: 3)
        controller.perform(.continueExecution)
        await reads.open()
        try await waitUntil { session.performedCommands == [.continueExecution] }

        #expect(Array(session.callLog.prefix(2)) == ["set 3", "perform continueExecution"])
        #expect(session.overlappingCallCount == 0)
        controller.stop()
        try await waitUntil { controller.hasEnded }
    }

    @Test("Stopping while the preparation question is up withdraws it and leaves the tab to show Stopped")
    func stopWithdrawsThePreparationQuestion() async throws {
        let answer = AsyncGate()
        let preparation = PluginDebugPreparation(message: "m", informativeText: nil, actionTitle: "Compile", statements: ["X"])
        let drivers = DebugDriverLog()
        var asked = false
        let (controller, debugger) = RoutineDebugFixtures.controller(
            drivers: drivers,
            plan: RoutineDebugFixtures.plan(preparation: preparation),
            confirmPreparation: { _ in
                asked = true
                await answer.wait()
                return false
            },
            withdrawPreparation: { Task { await answer.open() } }
        )
        var cancelled = false
        controller.onCancelled = { cancelled = true }
        controller.start()
        try await waitUntil { asked }

        controller.stop()
        try await waitUntil { controller.hasEnded }

        #expect(!cancelled)
        #expect(debugger.startRequests.isEmpty)
        #expect(drivers.openedCount == 0)
        guard case .stopped = controller.state else {
            Issue.record("expected stopped, got \(controller.state)")
            return
        }
    }

    @Test("A breakpoint the engine cannot place drops its marker")
    func unplaceableBreakpointDropsItsMarker() async throws {
        let session = FakeDebugSession(placesBreakpoint: { _ in nil })
        let (controller, _) = RoutineDebugFixtures.controller(session: session)
        controller.start()
        try await waitUntil { controller.state.pausedLocation != nil && !controller.variables.isEmpty }

        controller.toggleBreakpoint(atLine: 1)
        try await waitUntil { !session.placedBreakpointRequests.isEmpty }
        try await waitUntil { controller.displayedBreakpointLines.isEmpty }

        #expect(!controller.hasBreakpoints)
        controller.stop()
        await controller.waitUntilEnded()
    }

    @Test("A frame of the previous stack cannot be chosen while the next pause's stack loads, and a frame shows its own source and variables")
    func frameSelectionWaitsForTheCurrentStack() async throws {
        let caller = PluginDebugUnit(identity: "caller", displayName: "caller()")
        let nextStack = AsyncGate()
        let session = FakeDebugSession(
            frames: [
                PluginDebugFrame(level: 0, location: nil, arguments: nil),
                PluginDebugFrame(level: 1, location: PluginDebugLocation(unit: caller, line: 5), arguments: nil),
            ],
            laterStackGate: nextStack
        )
        let (controller, _) = RoutineDebugFixtures.controller(session: session)
        controller.start()
        try await waitUntil { controller.stackIsCurrent && controller.displayedFrameLevel == 0 }

        controller.perform(.stepOver)
        try await waitUntil { session.stackReadCount == 2 }
        #expect(!controller.stackIsCurrent)
        controller.selectFrame(level: 1)
        #expect(controller.selectedFrameLevel != 1)
        await nextStack.open()
        try await waitUntil { controller.stackIsCurrent && session.variableReadLevels.count == 2 }
        try await waitUntil { controller.displayedFrameLevel == 0 }

        #expect(session.variableReadLevels == [0, 0])
        #expect(controller.displayedUnit == FakeDebugSession.unit)

        controller.selectFrame(level: 1)
        try await waitUntil { controller.displayedFrameLevel == 1 }
        #expect(controller.displayedUnit == caller)
        #expect(session.variableReadLevels.last == 1)
        #expect(controller.executionLine == 5)
        controller.stop()
        try await waitUntil { controller.hasEnded }
    }

    @Test("Stop during a slow read reaches the session at once, and its drivers close no earlier than the deadline")
    func stopDuringReadIsNotQueued() async throws {
        let reads = AsyncGate()
        let blocker = AsyncGate()
        let session = FakeDebugSession(stopBlocker: blocker, inspectGate: reads)
        let drivers = DebugDriverLog()
        let limit: Duration = .seconds(1)
        let (controller, _) = RoutineDebugFixtures.controller(session: session, drivers: drivers, cancelLimit: limit)
        controller.start()
        try await waitUntil { session.sourceReadCount == 1 }

        let asked = ContinuousClock.now
        controller.stop()
        try await waitUntil(timeout: .milliseconds(500)) { session.stopCount == 1 }
        #expect(session.stopOverlapCount == 1)
        #expect(drivers.closedCount == 0)
        try await waitUntil { controller.hasEnded }

        #expect(drivers.closedCount == 2)
        #expect(drivers.closeInstants.allSatisfy { $0 >= asked.advanced(by: limit) })
        #expect(session.stackReadCount == 0)
        #expect(controller.inspectionError == nil)
        #expect(controller.statusText == RoutineDebugController.stopNotConfirmed)
        await blocker.open()
    }

    @Test("Drivers close as soon as the plugin answers the stop, before the deadline")
    func driversCloseWhenStopReturns() async throws {
        let reads = AsyncGate()
        let session = FakeDebugSession(inspectGate: reads)
        let drivers = DebugDriverLog()
        let limit: Duration = .seconds(5)
        let (controller, _) = RoutineDebugFixtures.controller(session: session, drivers: drivers, cancelLimit: limit)
        controller.start()
        try await waitUntil { session.sourceReadCount == 1 }

        let asked = ContinuousClock.now
        controller.stop()
        try await waitUntil { controller.hasEnded }

        #expect(session.stopCount == 1)
        #expect(drivers.closedCount == 2)
        #expect(drivers.closeInstants.allSatisfy { $0 < asked.advanced(by: limit) })
        #expect(controller.statusText == String(localized: "Stopped"))
    }

    @Test("A new pause never shows the last pause's variables, even when its own fail to load")
    func newPauseClearsVariables() async throws {
        let session = FakeDebugSession(failsLaterVariables: true)
        let (controller, _) = RoutineDebugFixtures.controller(session: session)
        controller.start()
        try await waitUntil { controller.state.pausedLocation != nil && !controller.variables.isEmpty }

        controller.perform(.stepInto)
        try await waitUntil { controller.state.pausedLocation?.line == 3 && controller.inspectionError != nil }

        #expect(controller.variables.isEmpty)
        #expect(controller.displayedFrameLevel == nil)
        controller.stop()
        try await waitUntil { controller.hasEnded }
    }

    @Test("Toggle Breakpoint and Remove All are offered only when they can act")
    func breakpointCommandsValidate() async throws {
        let (controller, _) = RoutineDebugFixtures.controller()
        #expect(!controller.canToggleBreakpoint)
        controller.start()
        try await waitUntil { controller.state.pausedLocation != nil && !controller.variables.isEmpty }

        #expect(!controller.canToggleBreakpoint)
        controller.cursorLine = 3
        #expect(controller.canToggleBreakpoint)
        #expect(!controller.canRemoveAllBreakpoints)
        controller.toggleBreakpointAtCursor()
        #expect(controller.canRemoveAllBreakpoints)

        controller.stop()
        try await waitUntil { controller.hasEnded }
        #expect(!controller.canToggleBreakpoint)
        #expect(!controller.canRemoveAllBreakpoints)
    }

    @Test("Toggle Breakpoint acts on the cursor's line")
    func toggleAtCursor() async throws {
        let (controller, _) = RoutineDebugFixtures.controller()
        controller.start()
        try await waitUntil { controller.state.pausedLocation != nil && !controller.variables.isEmpty }

        controller.cursorLine = 4
        controller.toggleBreakpointAtCursor()
        try await waitUntil { controller.displayedBreakpointLines == [4] }
        controller.removeAllBreakpoints()

        #expect(!controller.hasBreakpoints)
        controller.stop()
        await controller.waitUntilEnded()
    }

    @Test("Output relayed as the routine finishes still reaches the tab")
    func outputRelayedAtFinishIsKept() async throws {
        let relay = AsyncGate()
        let session = FakeDebugSession(relayedOutput: (gate: relay, lines: ["NOTICE: total is 1", "done"]))
        let (controller, _) = RoutineDebugFixtures.controller(session: session)
        controller.start()
        try await waitUntil { controller.state.pausedLocation != nil && !controller.variables.isEmpty }

        controller.perform(.continueExecution)
        try await waitUntil { session.performedCommands == [.continueExecution] }
        await relay.open()
        try await waitUntil { controller.hasEnded }

        #expect(controller.outputLines == ["NOTICE: total is 1", "done"])
        guard case .finished = controller.state else {
            Issue.record("expected finished, got \(controller.state)")
            return
        }
    }

    @Test("A target whose stop never returns loses its connections at the limit")
    func stuckTargetStopIsCapped() async throws {
        let blocker = AsyncGate()
        let session = FakeDebugSession(stopBlocker: blocker)
        let drivers = DebugDriverLog()
        let (controller, _) = RoutineDebugFixtures.controller(
            session: session,
            drivers: drivers,
            cancelLimit: .milliseconds(50)
        )
        controller.start()
        try await waitUntil { controller.state.pausedLocation != nil }

        controller.stop()
        try await waitUntil { controller.hasEnded }

        #expect(session.stopCount == 1)
        #expect(drivers.closedCount == 2)
        #expect(controller.statusText == RoutineDebugController.stopNotConfirmed)
        await blocker.open()
    }

    @Test("Output lines from the session reach the tab")
    func outputLinesArrive() async throws {
        let session = FakeDebugSession()
        let (controller, _) = RoutineDebugFixtures.controller(session: session)
        controller.start()
        try await waitUntil { controller.state.pausedLocation != nil }

        session.emit("NOTICE: total is 0")
        try await waitUntil { controller.outputLines == ["NOTICE: total is 0"] }
        controller.stop()
        await controller.waitUntilEnded()
    }
}

// Records what was asked and allows it, so a test can pin the request the run makes.
private final class RecordingGate: ExecutionGate, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [OperationRequest] = []

    var requests: [OperationRequest] { lock.withLock { recorded } }

    func authorize(_ request: OperationRequest) async -> OperationDecision {
        lock.withLock { recorded.append(request) }
        return await AlwaysAllowGate().authorize(request)
    }
}
