import AppKit
import Foundation

// WorkspaceContextCloseCoordinator.swift — atomic preflight/save/discard/close of every window in one context
// Part of the Database Context Rail feature (Task 4 of the plan).

@MainActor
internal final class WorkspaceContextCloseCoordinator {
    private let registry: WorkspaceContextRegistry
    private let confirmWindow: (UUID) async -> Bool
    private let closeWindow: (UUID) -> Void
    private let activate: (WorkspaceContextKey) -> Void

    internal static let shared = WorkspaceContextCloseCoordinator()

    internal init(
        registry: WorkspaceContextRegistry = .shared,
        confirmWindow: ((UUID) async -> Bool)? = nil,
        closeWindow: ((UUID) -> Void)? = nil,
        activate: ((WorkspaceContextKey) -> Void)? = nil
    ) {
        self.registry = registry
        self.confirmWindow = confirmWindow ?? WorkspaceContextCloseCoordinator.confirmRegisteredWindow
        self.closeWindow = closeWindow ?? WorkspaceContextCloseCoordinator.commitRegisteredWindow
        self.activate = activate ?? { key in
            WorkspaceContextActivationCoordinator.shared.activate(key)
        }
    }

    internal func close(key: WorkspaceContextKey, sourceWindow _: NSWindow?) async -> Bool {
        let windowIds = registry.windowIds(for: key)

        // Confirm every window before any close. A later cancel must leave earlier
        // windows open and still registered.
        for windowId in windowIds {
            guard await confirmWindow(windowId) else { return false }
        }

        for windowId in windowIds {
            closeWindow(windowId)
            registry.unregister(windowId: windowId)
        }

        if registry.contains(key) {
            registry.unregisterAll(for: key)
        }

        if let nextKey = registry.selectedKey {
            activate(nextKey)
        }

        return true
    }

    /// Unsaved SQL, pending grid edits, and a running query all prompt here.
    /// Nothing is closed or unregistered until every window has agreed.
    private static func confirmRegisteredWindow(_ windowId: UUID) async -> Bool {
        guard let coordinator = MainContentCoordinator.coordinator(for: windowId) else {
            return true
        }
        if let actions = coordinator.commandActions {
            return await actions.confirmWindowClose()
        }
        // A live coordinator without command actions still has work that
        // confirmWindowClose would have prompted for. Do not discard it.
        if coordinator.hasAnyUnsavedWork() { return false }
        if coordinator.toolbarState.isExecuting { return false }
        return true
    }

    private static func commitRegisteredWindow(_ windowId: UUID) {
        guard let coordinator = MainContentCoordinator.coordinator(for: windowId) else { return }
        if let actions = coordinator.commandActions {
            actions.commitWindowClose(asBatchSurvivor: false)
            return
        }
        coordinator.contentWindow?.close()
    }
}
