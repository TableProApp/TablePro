//
//  RoutineDebugSessions.swift
//  TablePro
//

import AppKit
import Foundation
import os
import TableProPluginKit

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

// Every live debug run, by the tab that shows it. Its connection can move to another window, so nothing here keeps one.
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
    // against the old transport is refused even after the fence opens again. Replacements nest; the last to end opens it.
    private var fenceDepths: [UUID: Int] = [:]
    private var admissionGenerations: [UUID: Int] = [:]
    // Runs a disconnect ended: the connection's teardown takes their tabs before anyone reads their status.
    private var unseenEndTabs: Set<UUID> = []
    // Choosers, start sheets and preparation alerts still on screen, so turning the module off can take them down.
    private var pendingSetups: [ObjectIdentifier: RoutineDebugSetup] = [:]
    private var moduleObserver: NSObjectProtocol?
    private let isModuleEnabled: @MainActor () -> Bool
    private let notificationCenter: NotificationCenter
    private let reportUnconfirmedStop: @MainActor (RoutineDebugController, NSWindow?) -> Void

    init(
        isModuleEnabled: @escaping @MainActor () -> Bool = { AppModuleSettings.shared.isEnabled(.routineDebugger) },
        notificationCenter: NotificationCenter = .default,
        reportUnconfirmedStop: @escaping @MainActor (RoutineDebugController, NSWindow?) -> Void =
            RoutineDebugSessions.presentUnconfirmedStop
    ) {
        self.isModuleEnabled = isModuleEnabled
        self.notificationCenter = notificationCenter
        self.reportUnconfirmedStop = reportUnconfirmedStop
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
        fenceDepths[connectionId] == nil && admissionGeneration(for: connectionId) == generation
    }

    // After the transport is up again, or gone for good. Starts read before the fence closed stay refused.
    func reopenAdmission(for connectionId: UUID) {
        guard let depth = fenceDepths[connectionId] else { return }
        fenceDepths[connectionId] = depth > 1 ? depth - 1 : nil
    }

    private func closeAdmission(for connectionId: UUID) {
        fenceDepths[connectionId, default: 0] += 1
        admissionGenerations[connectionId] = admissionGeneration(for: connectionId) + 1
    }

    func controller(forTab tabId: UUID) -> RoutineDebugController? {
        entries[tabId]?.controller
    }

    // The tab is going away: its run stops and its drivers close, without anyone waiting on it. With no tab left to
    // show it, a stop the plugin could not confirm is reported on `window`, the one that held the tab.
    func endSession(forTab tabId: UUID, window: NSWindow? = nil) {
        guard let entry = entries.removeValue(forKey: tabId) else { return }
        entry.controller.onCancelled = nil
        guard !entry.controller.hasEnded else {
            if unseenEndTabs.remove(tabId) != nil, entry.controller.unconfirmedStop != nil {
                let controller = entry.controller
                // A turn later, so a window closing with the tab is gone and the alert lands on one that stays.
                Task { [weak self, weak window] in
                    self?.reportUnconfirmedStop(controller, window)
                }
            }
            stopObservingIfIdle()
            return
        }
        unseenEndTabs.remove(tabId)
        ending[tabId] = entry
        entry.controller.stop()
        Task { [weak self, weak window] in
            await entry.controller.waitUntilEnded()
            guard let self else { return }
            self.ending.removeValue(forKey: tabId)
            if entry.controller.unconfirmedStop != nil {
                self.reportUnconfirmedStop(entry.controller, window)
            }
            self.stopObservingIfIdle()
        }
    }

    func endSessions(forTabs tabIds: [UUID], window: NSWindow? = nil) {
        for tabId in tabIds {
            endSession(forTab: tabId, window: window)
        }
    }

    // The target may still hold its locks. A quit in progress shows nothing: the process is about to end its connections.
    static func presentUnconfirmedStop(of controller: RoutineDebugController, in window: NSWindow?) {
        guard let text = controller.unconfirmedStop,
              !AppModuleTermination.hasBegun,
              !MainContentCoordinator.isAppTerminating
        else { return }
        let alert = NSAlert()
        alert.messageText = String(format: String(localized: "%@ May Still Be Running"), controller.plan.target.name)
        alert.informativeText = text
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "OK"))
        AlertHelper.present(alert, in: window?.isVisible == true ? window : nil)
    }

    // Before the connection's transport goes, so every target is aborted while it can still be reached. Closes the
    // connection's admission first, so a start racing this cannot open a driver on the transport being torn down; the
    // caller reopens it with `reopenAdmission(for:)` once the new transport is up.
    // `tabsCloseAfter`: the caller tears the connection's tabs down next, so an unconfirmed stop is reported then.
    func stopAll(connectionId: UUID, timeout: Duration = defaultStopTimeout, tabsCloseAfter: Bool = false) async {
        let deadline = RoutineDebugStopDeadline(after: timeout)
        closeAdmission(for: connectionId)
        let controllers = (entries.values.map { $0 } + ending.values.map { $0 })
            .filter { $0.connectionId == connectionId }
            .map(\.controller)
        await stopAndWait(controllers, by: deadline)
        guard tabsCloseAfter else { return }
        for (tabId, entry) in entries where entry.connectionId == connectionId {
            unseenEndTabs.insert(tabId)
        }
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
