//
//  RoutineDebugSessions.swift
//  TablePro
//

import Foundation
import os

// T0 plus the stop limit, fixed when a stop is first asked for. Every wait in that stop, and every caller waiting on
// it, runs against this one instant, so no connection closes before the plugin answered or the instant passed.
internal struct RoutineDebugStopDeadline: Sendable {
    let instant: ContinuousClock.Instant

    init(after limit: Duration) {
        instant = ContinuousClock.now.advanced(by: limit)
    }

    // True when `work` returned first. Work still running at the deadline is left running.
    @MainActor
    func wait(for work: @escaping @MainActor @Sendable () async -> Void) async -> Bool {
        await AppModuleTermination.runCapped(at: ContinuousClock.now.duration(to: instant), work)
    }
}

// Every live debug run, by the tab that shows it. A tab can move between windows, so nothing here belongs to a window.
@MainActor
internal final class RoutineDebugSessions {
    static let shared = RoutineDebugSessions()

    // Long enough for a reachable server to abort and roll back, short enough that a disconnect never hangs on one that isn't.
    static let defaultStopTimeout: Duration = .seconds(5)

    private static let logger = Logger(subsystem: "com.TablePro", category: "RoutineDebugSessions")

    private struct Entry {
        let controller: RoutineDebugController
        let connectionId: UUID
    }

    private var entries: [UUID: Entry] = [:]
    private var ending: [UUID: Entry] = [:]
    // Per connection: closed while its transport is torn down or replaced, and bumped each time, so a start set up
    // against the old transport is refused even after the fence opens again.
    private var fencedConnections: Set<UUID> = []
    private var admissionGenerations: [UUID: Int] = [:]
    // Choosers, start sheets and preparation alerts still on screen, so turning the module off can take them down.
    private var pendingSetups: [ObjectIdentifier: RoutineDebugSetup] = [:]
    private var moduleObserver: NSObjectProtocol?
    private let isModuleEnabled: @MainActor () -> Bool
    private let notificationCenter: NotificationCenter

    init(
        isModuleEnabled: @escaping @MainActor () -> Bool = { AppModuleSettings.shared.isEnabled(.routineDebugger) },
        notificationCenter: NotificationCenter = .default
    ) {
        self.isModuleEnabled = isModuleEnabled
        self.notificationCenter = notificationCenter
    }

    var hasActiveSessions: Bool {
        entries.values.contains { !$0.controller.hasEnded } || !ending.isEmpty
    }

    // Refused once the connection's transport went away after `generation` was read; nil means now.
    @discardableResult
    func register(
        _ controller: RoutineDebugController,
        tabId: UUID,
        connectionId: UUID,
        generation: Int? = nil
    ) -> Bool {
        guard admits(connectionId, generation: generation ?? admissionGeneration(for: connectionId)) else { return false }
        entries[tabId] = Entry(controller: controller, connectionId: connectionId)
        observeModuleIfNeeded()
        return true
    }

    // MARK: - Setups

    func beginSetup(_ setup: RoutineDebugSetup) {
        pendingSetups[ObjectIdentifier(setup)] = setup
        observeModuleIfNeeded()
    }

    func endSetup(_ setup: RoutineDebugSetup) {
        pendingSetups.removeValue(forKey: ObjectIdentifier(setup))
        stopObservingIfIdle()
    }

    // MARK: - Admission

    func admissionGeneration(for connectionId: UUID) -> Int {
        admissionGenerations[connectionId] ?? 0
    }

    func admits(_ connectionId: UUID, generation: Int) -> Bool {
        !fencedConnections.contains(connectionId) && admissionGeneration(for: connectionId) == generation
    }

    // After the transport is up again, or gone for good. Starts read before the fence closed stay refused.
    func reopenAdmission(for connectionId: UUID) {
        fencedConnections.remove(connectionId)
    }

    private func closeAdmission(for connectionId: UUID) {
        fencedConnections.insert(connectionId)
        admissionGenerations[connectionId] = admissionGeneration(for: connectionId) + 1
    }

    func controller(forTab tabId: UUID) -> RoutineDebugController? {
        entries[tabId]?.controller
    }

    // The tab is going away: its run stops and its drivers close, without anyone waiting on it.
    func endSession(forTab tabId: UUID) {
        guard let entry = entries.removeValue(forKey: tabId) else { return }
        entry.controller.onCancelled = nil
        guard !entry.controller.hasEnded else {
            stopObservingIfIdle()
            return
        }
        ending[tabId] = entry
        entry.controller.stop()
        Task { [weak self] in
            await entry.controller.waitUntilEnded()
            self?.ending.removeValue(forKey: tabId)
            self?.stopObservingIfIdle()
        }
    }

    func endSessions(forTabs tabIds: [UUID]) {
        for tabId in tabIds {
            endSession(forTab: tabId)
        }
    }

    // Before the connection's transport goes, so every target is aborted while it can still be reached. Closes the
    // connection's admission first, so a start racing this cannot open a driver on the transport being torn down; the
    // caller reopens it with `reopenAdmission(for:)` once the new transport is up.
    func stopAll(connectionId: UUID, timeout: Duration = defaultStopTimeout) async {
        let deadline = RoutineDebugStopDeadline(after: timeout)
        closeAdmission(for: connectionId)
        let controllers = (entries.values.map { $0 } + ending.values.map { $0 })
            .filter { $0.connectionId == connectionId }
            .map(\.controller)
        await stopAndWait(controllers, by: deadline)
    }

    func stopAll(timeout: Duration = defaultStopTimeout) async {
        let deadline = RoutineDebugStopDeadline(after: timeout)
        let controllers = entries.values.map(\.controller) + ending.values.map(\.controller)
        await stopAndWait(controllers, by: deadline)
    }

    // The runs close their drivers by the same deadline this waits for, so the caller's transport outlives them.
    private func stopAndWait(_ controllers: [RoutineDebugController], by deadline: RoutineDebugStopDeadline) async {
        let live = controllers.filter { !$0.hasEnded }
        guard !live.isEmpty else { return }
        for controller in live {
            controller.stop(by: deadline)
        }
        let finished = await deadline.wait {
            for controller in live {
                await controller.waitUntilEnded()
            }
        }
        if !finished {
            Self.logger.warning("Debug sessions still stopping at their deadline; continuing without them")
        }
    }

    // MARK: - Module

    // Observed only while a run or a setup exists, so an off module leaves no observer behind.
    private func observeModuleIfNeeded() {
        guard moduleObserver == nil else { return }
        moduleObserver = notificationCenter.addObserver(
            forName: .appModulesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.moduleDidChange()
            }
        }
    }

    private func stopObservingIfIdle() {
        guard entries.isEmpty, ending.isEmpty, pendingSetups.isEmpty, let moduleObserver else { return }
        notificationCenter.removeObserver(moduleObserver)
        self.moduleObserver = nil
    }

    private func moduleDidChange() {
        guard !isModuleEnabled() else { return }
        let setups = Array(pendingSetups.values)
        pendingSetups.removeAll()
        for setup in setups {
            setup.cancel()
        }
        for coordinator in MainContentCoordinator.activeCoordinators.values {
            coordinator.closeRoutineDebugTabs()
        }
        endSessions(forTabs: Array(entries.keys))
    }
}
