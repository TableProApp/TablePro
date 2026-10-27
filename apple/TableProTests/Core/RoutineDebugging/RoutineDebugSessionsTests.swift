//
//  RoutineDebugSessionsTests.swift
//  TableProTests
//

import AppKit
import Foundation
@testable import TablePro
import TableProPluginKit
import TableProTestSupport
import Testing

@MainActor
private final class UnconfirmedStopRecorder {
    private(set) var texts: [String?] = []
    private(set) var windows: [NSWindow?] = []

    func record(_ controller: RoutineDebugController, _ window: NSWindow?) {
        texts.append(controller.unconfirmedStop)
        windows.append(window)
    }
}

@MainActor
struct RoutineDebugSessionsTests {
    @Test("Stopping a connection's runs closes their drivers at the caller's deadline when a target cannot be reached")
    func stopAllSharesItsDeadline() async throws {
        let blocker = AsyncGate()
        let session = FakeDebugSession(stopBlocker: blocker)
        let drivers = DebugDriverLog()
        let (controller, _) = RoutineDebugFixtures.controller(session: session, drivers: drivers, cancelLimit: .seconds(30))
        let registry = RoutineDebugSessions(isModuleEnabled: { true })
        let connectionId = UUID()
        registry.register(controller, tabId: UUID(), connectionId: connectionId)
        controller.start()
        try await waitUntil { controller.state.pausedLocation != nil }

        let timeout: Duration = .milliseconds(200)
        let asked = ContinuousClock.now
        await registry.stopAll(connectionId: connectionId, timeout: timeout)
        #expect(ContinuousClock.now >= asked.advanced(by: timeout))
        try await waitUntil(timeout: .seconds(2)) { controller.hasEnded }

        #expect(session.stopCount == 1)
        #expect(drivers.closedCount == 2)
        #expect(drivers.closeInstants.allSatisfy { $0 >= asked.advanced(by: timeout) })
        #expect(controller.statusText == RoutineDebugController.stopNotConfirmed)
        await blocker.open()
    }

    @Test("Closing the tab while the debugger is still starting cancels the start and closes its drivers")
    func endSessionWhileStarting() async throws {
        let session = FakeDebugSession()
        let drivers = DebugDriverLog()
        let (controller, debugger) = RoutineDebugFixtures.controller(
            session: session,
            drivers: drivers,
            startBehavior: .untilCancelled
        )
        let registry = RoutineDebugSessions(isModuleEnabled: { true })
        let tabId = UUID()
        registry.register(controller, tabId: tabId, connectionId: UUID())
        controller.start()
        try await waitUntil { drivers.openedCount == 2 }

        registry.endSession(forTab: tabId)
        try await waitUntil { controller.hasEnded }

        #expect(debugger.startWasCancelled)
        #expect(drivers.closedCount == 2)
        guard case .stopped = controller.state else {
            Issue.record("expected stopped, got \(controller.state)")
            return
        }
        try await waitUntil { !registry.hasActiveSessions }
    }

    @Test("A start racing a connection's stop is refused and opens no driver; after the reconnect a fresh start works")
    func admissionFence() async throws {
        let registry = RoutineDebugSessions(isModuleEnabled: { true })
        let connectionId = UUID()
        let staleGeneration = registry.admissionGeneration(for: connectionId)
        let staleDrivers = DebugDriverLog()
        let (stale, _) = RoutineDebugFixtures.controller(drivers: staleDrivers, admits: {
            await registry.admits(connectionId, generation: staleGeneration)
        })

        await registry.stopAll(connectionId: connectionId)
        #expect(!registry.register(stale, tabId: UUID(), connectionId: connectionId, generation: staleGeneration))
        stale.start()
        try await waitUntil { stale.hasEnded }
        #expect(staleDrivers.openedCount == 0)
        guard case .failed(let message) = stale.state else {
            Issue.record("expected failed, got \(stale.state)")
            return
        }
        #expect(message == RoutineDebugError.connectionChanged.localizedDescription)

        registry.reopenAdmission(for: connectionId)
        #expect(!registry.admits(connectionId, generation: staleGeneration))
        let freshGeneration = registry.admissionGeneration(for: connectionId)
        let freshDrivers = DebugDriverLog()
        let (fresh, _) = RoutineDebugFixtures.controller(drivers: freshDrivers, admits: {
            await registry.admits(connectionId, generation: freshGeneration)
        })
        #expect(registry.register(fresh, tabId: UUID(), connectionId: connectionId, generation: freshGeneration))
        fresh.start()
        try await waitUntil { fresh.state.pausedLocation != nil }
        #expect(freshDrivers.openedCount == 2)
        fresh.stop()
        try await waitUntil { fresh.hasEnded }
    }

    @Test("A run counts as active until its tab's stop has finished")
    func activeUntilStopped() async throws {
        let registry = RoutineDebugSessions(isModuleEnabled: { true })
        let (controller, _) = RoutineDebugFixtures.controller()
        let tabId = UUID()
        #expect(!registry.hasActiveSessions)

        registry.register(controller, tabId: tabId, connectionId: UUID())
        controller.start()
        try await waitUntil { controller.state.pausedLocation != nil }
        #expect(registry.hasActiveSessions)

        registry.endSession(forTab: tabId)
        #expect(registry.controller(forTab: tabId) == nil)
        try await waitUntil { !registry.hasActiveSessions }
        #expect(controller.hasEnded)
    }

    @Test("Turning the module off during a preparation statement closes its driver, and the session never starts")
    func moduleOffDuringPreparationStatement() async throws {
        let center = NotificationCenter()
        let registry = RoutineDebugSessions(isModuleEnabled: { false }, notificationCenter: center)
        let drivers = DebugDriverLog(statements: .untilCancelled)
        let preparation = PluginDebugPreparation(
            message: "Compile for debugging?",
            informativeText: nil,
            actionTitle: "Compile for Debug",
            statements: ["ALTER PACKAGE p COMPILE BODY"]
        )
        let (controller, debugger) = RoutineDebugFixtures.controller(
            drivers: drivers,
            plan: RoutineDebugFixtures.plan(preparation: preparation)
        )
        registry.register(controller, tabId: UUID(), connectionId: UUID())
        controller.start()
        try await waitUntil { drivers.executedCount == 1 }

        center.post(name: .appModulesDidChange, object: AppModule.routineDebugger)
        try await waitUntil { controller.hasEnded }

        #expect(drivers.closedCount == 1)
        #expect(debugger.startRequests.isEmpty)
        guard case .stopped = controller.state else {
            Issue.record("expected stopped, got \(controller.state)")
            return
        }
        try await waitUntil { !registry.hasActiveSessions }
    }

    @Test("Turning the module off while the gate is still asking withdraws it, ends the run and drops the observer")
    func moduleOffWhileTheGateAsks() async throws {
        let center = NotificationCenter()
        let registry = RoutineDebugSessions(isModuleEnabled: { false }, notificationCenter: center)
        let gate = WaitingGate()
        let (controller, debugger) = RoutineDebugFixtures.controller(gate: gate)
        registry.register(controller, tabId: UUID(), connectionId: UUID())
        controller.start()
        try await waitUntil { gate.askedCount == 1 }

        center.post(name: .appModulesDidChange, object: AppModule.routineDebugger)
        try await waitUntil { controller.hasEnded }

        #expect(gate.sawCancellation)
        #expect(debugger.startRequests.isEmpty)
        try await waitUntil { !registry.hasActiveSessions }
    }

    @Test("Turning the module off ends every run the registry holds")
    func moduleOffEndsRuns() async throws {
        let center = NotificationCenter()
        let registry = RoutineDebugSessions(isModuleEnabled: { false }, notificationCenter: center)
        let session = FakeDebugSession()
        let tabId = UUID()
        let (controller, _) = RoutineDebugFixtures.controller(session: session)
        registry.register(controller, tabId: tabId, connectionId: UUID())
        controller.start()
        try await waitUntil { controller.state.pausedLocation != nil }

        center.post(name: .appModulesDidChange, object: AppModule.routineDebugger)
        await controller.waitUntilEnded()

        #expect(session.stopCount == 1)
        #expect(registry.controller(forTab: tabId) == nil)
        try await waitUntil { !registry.hasActiveSessions }
    }

    @Test("A stop the plugin cannot confirm after its tab closed is reported on the window that held the tab")
    func unconfirmedStopOfClosedTabIsReported() async throws {
        let recorder = UnconfirmedStopRecorder()
        let registry = RoutineDebugSessions(isModuleEnabled: { true }, reportUnconfirmedStop: { recorder.record($0, $1) })
        let session = FakeDebugSession(stopOutcome: .unconfirmed(
            message: "Server process 4242 may still be running.",
            detail: "End it with pg_terminate_backend(4242)."
        ))
        let (controller, _) = RoutineDebugFixtures.controller(session: session)
        let tabId = UUID()
        registry.register(controller, tabId: tabId, connectionId: UUID())
        controller.start()
        try await waitUntil { controller.state.pausedLocation != nil }
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false

        registry.endSession(forTab: tabId, window: window)
        try await waitUntil { !registry.hasActiveSessions }

        #expect(recorder.texts == ["Server process 4242 may still be running.\nEnd it with pg_terminate_backend(4242)."])
        #expect(recorder.windows.count == 1 && recorder.windows[0] === window)
    }

    @Test("A confirmed stop after the tab closed reports nothing")
    func confirmedStopOfClosedTabIsNotReported() async throws {
        let recorder = UnconfirmedStopRecorder()
        let registry = RoutineDebugSessions(isModuleEnabled: { true }, reportUnconfirmedStop: { recorder.record($0, $1) })
        let session = FakeDebugSession()
        let (controller, _) = RoutineDebugFixtures.controller(session: session)
        let tabId = UUID()
        registry.register(controller, tabId: tabId, connectionId: UUID())
        controller.start()
        try await waitUntil { controller.state.pausedLocation != nil }

        registry.endSession(forTab: tabId)
        try await waitUntil { !registry.hasActiveSessions }

        #expect(session.stopCount == 1)
        #expect(recorder.texts.isEmpty)
    }

    @Test("An unconfirmed stop that ended while its tab still showed it is not reported again when the tab closes")
    func unconfirmedStopShownInItsTabIsNotReported() async throws {
        let recorder = UnconfirmedStopRecorder()
        let registry = RoutineDebugSessions(isModuleEnabled: { true }, reportUnconfirmedStop: { recorder.record($0, $1) })
        let session = FakeDebugSession(stopOutcome: .unconfirmed(message: "Server process 4242 may still be running.", detail: nil))
        let (controller, _) = RoutineDebugFixtures.controller(session: session)
        let tabId = UUID()
        let connectionId = UUID()
        registry.register(controller, tabId: tabId, connectionId: connectionId)
        controller.start()
        try await waitUntil { controller.state.pausedLocation != nil }

        await registry.stopAll(connectionId: connectionId)
        registry.reopenAdmission(for: connectionId)
        try await waitUntil { controller.hasEnded }
        registry.endSession(forTab: tabId)
        try await waitUntil { !registry.hasActiveSessions }

        #expect(controller.unconfirmedStop != nil)
        #expect(recorder.texts.isEmpty)
    }

    @Test("An unconfirmed stop a disconnect caused is reported once its tab goes with the connection")
    func unconfirmedStopOfDisconnectIsReportedWhenItsTabCloses() async throws {
        let recorder = UnconfirmedStopRecorder()
        let registry = RoutineDebugSessions(isModuleEnabled: { true }, reportUnconfirmedStop: { recorder.record($0, $1) })
        let session = FakeDebugSession(stopOutcome: .unconfirmed(message: "Server process 4242 may still be running.", detail: nil))
        let (controller, _) = RoutineDebugFixtures.controller(session: session)
        let tabId = UUID()
        let connectionId = UUID()
        registry.register(controller, tabId: tabId, connectionId: connectionId)
        controller.start()
        try await waitUntil { controller.state.pausedLocation != nil }

        await registry.stopAll(connectionId: connectionId, tabsCloseAfter: true)
        registry.reopenAdmission(for: connectionId)
        try await waitUntil { controller.hasEnded }
        #expect(recorder.texts.isEmpty)
        registry.endSession(forTab: tabId)
        try await waitUntil { recorder.texts.count == 1 }

        #expect(recorder.texts == ["Server process 4242 may still be running."])
    }

    @Test("Two overlapping transport replacements keep the fence closed until the second one ends")
    func nestedFencesReopenOnTheLast() async {
        let registry = RoutineDebugSessions(isModuleEnabled: { true })
        let connectionId = UUID()

        await registry.stopAll(connectionId: connectionId)
        await registry.stopAll(connectionId: connectionId)
        let generation = registry.admissionGeneration(for: connectionId)

        registry.reopenAdmission(for: connectionId)
        #expect(!registry.admits(connectionId, generation: generation))

        registry.reopenAdmission(for: connectionId)
        #expect(registry.admits(connectionId, generation: generation))

        registry.reopenAdmission(for: connectionId)
        await registry.stopAll(connectionId: connectionId)
        #expect(!registry.admits(connectionId, generation: registry.admissionGeneration(for: connectionId)))
    }
}
