import AppKit
import Foundation

// WorkspaceContextActivationCoordinator.swift — reconnect/database/schema activation and visible-group switching
// Part of the Database Context Rail feature (Task 3 of the plan).

@MainActor
internal final class WorkspaceContextActivationCoordinator {
    private var registry: WorkspaceContextRegistry

    internal static let shared = WorkspaceContextActivationCoordinator()

    internal init(registry: WorkspaceContextRegistry = .shared) {
        self.registry = registry
    }

    internal func openOrActivate(
        connection: DatabaseConnection,
        databaseName: String?,
        schemaName: String?,
        initialQuery _: String? = nil
    ) {
        let key = WorkspaceContextResolver.resolve(
            connection: connection,
            databaseName: databaseName,
            schemaName: schemaName,
            session: DatabaseManager.shared.session(for: connection.id)
        )
        activate(key)
    }

    internal func activate(
        _ key: WorkspaceContextKey,
        preferredWindowId: UUID? = nil,
        sourceWindow _: NSWindow? = nil
    ) {
        guard let sequence = registry.beginActivation(for: key) else { return }

        let window = windowToRaise(for: key, preferredWindowId: preferredWindowId)
        if let window {
            if let group = window.tabGroup, group.selectedWindow !== window {
                group.selectedWindow = window
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }

        registry.commitActivation(key, request: sequence)
    }

    private func windowToRaise(for key: WorkspaceContextKey, preferredWindowId: UUID?) -> NSWindow? {
        if let preferredWindowId,
           let preferred = MainContentCoordinator.coordinator(for: preferredWindowId)?.contentWindow {
            return preferred
        }

        let registered = registry.windowIds(for: key).compactMap { windowId in
            MainContentCoordinator.coordinator(for: windowId)?.contentWindow
        }
        if let lastFocused = WindowLifecycleMonitor.shared.mostRecentWindow(for: key.connectionId),
           registered.contains(where: { $0 === lastFocused }) {
            return lastFocused
        }
        return registered.first
            ?? WindowLifecycleMonitor.shared.mostRecentWindow(for: key.connectionId)
    }
}
