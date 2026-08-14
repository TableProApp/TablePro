import Foundation

// WorkspaceContextCloseCoordinator.swift — atomic preflight/save/discard/close of every window in one context
// Part of the Database Context Rail feature (Task 4 of the plan).

@MainActor
internal final class WorkspaceContextCloseCoordinator {
    private let registry: WorkspaceContextRegistry
    private let windowManager: WindowManager
    private let databaseManager: DatabaseManager
    private let alertHelper: AlertHelper
    private let queryTabManager: QueryTabManager

    internal static let shared = WorkspaceContextCloseCoordinator()

    private init() {
        self.registry = WorkspaceContextRegistry()
        self.windowManager = WindowManager.shared
        self.databaseManager = DatabaseManager.shared
        self.alertHelper = AlertHelper.shared
        self.queryTabManager = QueryTabManager.shared
    }

    internal func close(key: WorkspaceContextKey, sourceWindow: NSWindow?) async -> Bool {
        let windowIds = registry.windowIds(for: key)
        guard !windowIds.isEmpty else { return true }

        // Preflight all in native order (existing safeguards reused)
        for windowId in windowIds {
            // Reused save/discard preflight from MainContentCommandActions / TabBatchClosePlanner
            // (integrates with existing unsaved SQL, data-grid changes, running queries)
            if !await preflightClose(for: windowId) {
                return false // cancel — context remains intact
            }
        }

        // All preflights passed — now close in order
        for windowId in windowIds {
            windowManager.close(windowId)
        }

        // Remove context after successful batch close
        registry.unregisterAll(for: key) // helper method
        // Activate most recently used remaining context
        if let nextKey = registry.selectedKey {
            activate(nextKey)
        }

        return true
    }

    private func preflightClose(for windowId: UUID) async -> Bool {
        // Reuse existing batch close logic from MainContentCommandActions+BulkClose.swift
        // (unsaved SQL, pending data-grid changes, running queries)
        // Return false on any cancel
        return true // placeholder — full integration in next steps
    }

    private func activate(_ key: WorkspaceContextKey) {
        // Reuse activation logic
        WorkspaceContextActivationCoordinator.shared.activate(key)
    }
}
