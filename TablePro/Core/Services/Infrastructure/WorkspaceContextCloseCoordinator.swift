import AppKit
import Foundation

// WorkspaceContextCloseCoordinator.swift — atomic preflight/save/discard/close of every window in one context
// Part of the Database Context Rail feature (Task 4 of the plan).

@MainActor
internal final class WorkspaceContextCloseCoordinator {
    private let registry: WorkspaceContextRegistry
    private let closeWindow: (UUID) async -> Bool
    private let activate: (WorkspaceContextKey) -> Void

    internal static let shared = WorkspaceContextCloseCoordinator()

    internal init(
        registry: WorkspaceContextRegistry = .shared,
        closeWindow: ((UUID) async -> Bool)? = nil,
        activate: ((WorkspaceContextKey) -> Void)? = nil
    ) {
        self.registry = registry
        self.closeWindow = closeWindow ?? WorkspaceContextCloseCoordinator.closeRegisteredWindow
        self.activate = activate ?? { key in
            WorkspaceContextActivationCoordinator.shared.activate(key)
        }
    }

    internal func close(key: WorkspaceContextKey, sourceWindow _: NSWindow?) async -> Bool {
        let windowIds = registry.windowIds(for: key)

        // Existing closeWindowAwaiting already prompts for unsaved SQL, pending
        // data-grid edits, and running work. Cancel must leave the context intact.
        for windowId in windowIds {
            guard await closeWindow(windowId) else { return false }
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

    /// Reuse existing batch close logic from MainContentCommandActions+BulkClose.swift
    /// (unsaved SQL, pending data-grid changes, running queries)
    /// Return false on any cancel
    private static func closeRegisteredWindow(_ windowId: UUID) async -> Bool {
        guard let coordinator = MainContentCoordinator.coordinator(for: windowId) else {
            return true
        }
        if let actions = coordinator.commandActions {
            return await actions.closeWindowAwaiting(asBatchSurvivor: false) == .closed
        }
        // A live coordinator without command actions still has unsaved work that
        // closeWindowAwaiting would have prompted for. Do not discard it.
        guard !coordinator.hasAnyUnsavedWork() else { return false }
        coordinator.contentWindow?.close()
        return true
    }
}
