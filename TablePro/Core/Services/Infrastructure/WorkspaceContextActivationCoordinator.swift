import Foundation

// WorkspaceContextActivationCoordinator.swift — reconnect/database/schema activation and visible-group switching
// Part of the Database Context Rail feature (Task 3 of the plan).

@MainActor
internal final class WorkspaceContextActivationCoordinator {
    private var registry: WorkspaceContextRegistry
    private var windowManager: WindowManager
    private var databaseManager: DatabaseManager
    private var alertHelper: AlertHelper

    internal static let shared = WorkspaceContextActivationCoordinator()

    private init() {
        self.registry = WorkspaceContextRegistry()
        self.windowManager = WindowManager.shared
        self.databaseManager = DatabaseManager.shared
        self.alertHelper = AlertHelper.shared
    }

    internal func openOrActivate(
        connection: DatabaseConnection,
        databaseName: String?,
        schemaName: String?,
        initialQuery: String? = nil
    ) {
        let key = WorkspaceContextKey.resolve(
            connection: connection,
            databaseName: databaseName,
            schemaName: schemaName,
            activeDatabase: nil,
            activeSchema: nil,
            supportsSchemaSwitching: true
        )
        activate(key)
    }

    internal func activate(
        _ key: WorkspaceContextKey,
        preferredWindowId: UUID? = nil,
        sourceWindow: NSWindow? = nil
    ) {
        guard let sequence = registry.beginActivation(for: key) else { return }
        // Reconnect, switch DB/schema (existing logic)
        // Activate the context's last-used native tab group
        // (WindowManager logic for grouping by tabbingIdentifier)
        registry.commitActivation(key, request: sequence)
        // Bring forward the context's last active window
        // (native tab group activation)
    }
}
