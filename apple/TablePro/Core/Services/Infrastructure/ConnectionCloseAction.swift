//
//  ConnectionCloseAction.swift
//  TablePro
//

import AppKit
import Foundation

// Disconnect keeps the connection to reconnect, an entry close takes one container, this ends the connection and every entry.
@MainActor
internal enum ConnectionCloseAction {
    // Asked in this order. The transaction comes last and is read then: a Save under Manual Commit lands in a held one.
    internal enum Decision: Equatable {
        case closeImmediately
        case confirmRunningWork
        case confirmUnsavedWork
        case confirmEndingTransaction
    }

    // Every window hosting the connection, every tab in each: saving only the selected tab closed over the rest.
    private static func saveEveryWindowsWork(
        across coordinators: [MainContentCoordinator],
        fallback: MainContentCoordinator?
    ) async -> Bool {
        let targets = coordinators.isEmpty ? [fallback].compactMap { $0 } : coordinators
        for coordinator in targets {
            guard await coordinator.commandActions?.saveEveryTabsWork() == true else { return false }
        }
        return !targets.isEmpty
    }

    private static func unsavedWorkMessage(across coordinators: [MainContentCoordinator]) -> String {
        let keepsTabsOpen = coordinators.contains { coordinator in
            coordinator.commandActions?.holdsWorkOnlyItsTabCanSave(among: coordinator.tabManager.tabs) == true
        }
        return MainContentCommandActions.unsavedWorkMessage(keepsTabsOpen: keepsTabsOpen)
    }

    // The Save alert names the running work, so the two never ask separately.
    internal static func decision(hasSession: Bool, hasRunningWork: Bool, hasUnsavedWork: Bool) -> Decision {
        if hasSession, hasUnsavedWork { return .confirmUnsavedWork }
        if hasRunningWork { return .confirmRunningWork }
        return hasSession ? .confirmEndingTransaction : .closeImmediately
    }

    internal static func close(connectionId: UUID, registry: RunningWorkRegistry = .shared) async {
        // Every window hosting the connection: a torn-off tab keeps its edits in its own coordinator.
        let coordinators = WindowManager.shared.coordinators(for: connectionId)
        let coordinator = coordinators.first ?? WindowManager.shared.coordinator(for: connectionId)
        let hasSession = coordinator != nil
        // Read at each decision: the window stays editable while the alerts are awaited.
        let hasUnsavedWork = {
            coordinators.contains { $0.hasAnyUnsavedWork() }
                || (coordinators.isEmpty && coordinator?.hasAnyUnsavedWork() == true)
        }

        // Shown, then asked; a close that closes nothing puts the user back where they were.
        let wasShowing = WindowManager.shared.shownConnection(besides: connectionId)
        func restore() {
            WindowManager.shared.show(wasShowing, inWindowHosting: connectionId)
        }
        let work = registry.items(in: .connection(connectionId))
        var namedWork = false
        var decision = decision(hasSession: hasSession, hasRunningWork: !work.isEmpty, hasUnsavedWork: hasUnsavedWork())

        if decision == .confirmRunningWork {
            if let prompt = RunningWorkPrompt.make(action: .close, work: work) {
                guard await RunningWorkApproval.confirm(prompt, window: reveal(connectionId: connectionId)) else {
                    restore()
                    return
                }
            }
            namedWork = true
            decision = Self.decision(hasSession: hasSession, hasRunningWork: false, hasUnsavedWork: hasUnsavedWork())
        }

        if decision == .confirmUnsavedWork {
            let targets = coordinators.isEmpty ? [coordinator].compactMap { $0 } : coordinators
            switch await AlertHelper.confirmSaveChanges(
                message: RunningWorkPrompt.saveMessage(
                    unsavedWorkMessage(across: targets),
                    action: .close,
                    alsoStopping: namedWork ? [] : work
                ),
                window: reveal(connectionId: connectionId)
            ) {
            case .save:
                guard await saveEveryWindowsWork(across: coordinators, fallback: coordinator) else {
                    restore()
                    return
                }
            case .dontSave:
                break
            case .cancel:
                restore()
                return
            }
            decision = .confirmEndingTransaction
        }

        if decision == .confirmEndingTransaction {
            let name = coordinator?.connection.name ?? DatabaseManager.shared.session(for: connectionId)?.connection.name ?? ""
            let outcome = await TransactionEndingFlow.resolve(
                connectionId: connectionId,
                action: .closeConnection(name: name),
                window: { reveal(connectionId: connectionId) }
            )
            guard outcome != .cancelled else {
                restore()
                return
            }
        }

        // Stopped only once the close is certain: a Cancel, a failed save or a failed commit keeps the work running.
        registry.cancel(work)
        WindowManager.shared.closeWindow(for: connectionId)
    }

    // The answer can name a connection never on screen, so it is brought forward first.
    @discardableResult
    private static func reveal(connectionId: UUID) -> NSWindow? {
        guard let window = WindowManager.shared.window(for: connectionId),
              let host = window.contentViewController as? MainSplitViewController else { return nil }
        if let group = window.tabGroup, group.selectedWindow !== window {
            group.selectedWindow = window
        }
        window.makeKeyAndOrderFront(nil)
        host.workspaces.select(connectionId)
        return window
    }
}
