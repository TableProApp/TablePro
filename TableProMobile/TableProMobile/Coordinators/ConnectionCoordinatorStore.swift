import Foundation
import Observation
import TableProDatabase
import TableProModels

/// Owns the live coordinator per connection, so a presented screen never writes back into the
/// state of the screen presenting it.
@MainActor
@Observable
final class ConnectionCoordinatorStore {
    /// Bumped whenever an entry is retired, so a screen already showing a coordinator rebuilds it
    /// instead of going on talking to a driver that has been disconnected underneath it.
    private(set) var revision = 0

    private var coordinators: [UUID: ConnectionCoordinator] = [:]
    private let connectionManager: ConnectionManager

    init(connectionManager: ConnectionManager) {
        self.connectionManager = connectionManager
    }

    func coordinator(for connection: DatabaseConnection, appState: AppState) -> ConnectionCoordinator {
        if let existing = coordinators[connection.id] { return existing }
        let created = ConnectionCoordinator(connection: connection, appState: appState)
        created.restorePersistedState()
        coordinators[connection.id] = created
        return created
    }

    func invalidate(_ id: UUID, droppingSession: Bool = true) {
        let removed = coordinators.removeValue(forKey: id)
        removed?.cancelConnect()
        revision += 1
        guard droppingSession else { return }
        let manager = connectionManager
        Task { await manager.disconnect(id) }
    }

    /// Only a change to how the app dials drops the live session. Sorting, grouping, tagging and
    /// renaming rewrite every connection, and a dragged row must not close a working one.
    func reconcile(from old: [DatabaseConnection], to new: [DatabaseConnection]) {
        let updated = Dictionary(uniqueKeysWithValues: new.map { ($0.id, $0) })
        for previous in old {
            let current = updated[previous.id]
            guard current != previous else { continue }
            let redials = current.map { !$0.dialsTheSameWay(as: previous) } ?? true
            invalidate(previous.id, droppingSession: redials)
        }
    }
}

nonisolated extension DatabaseConnection {
    func dialsTheSameWay(as other: DatabaseConnection) -> Bool {
        type == other.type
            && host == other.host
            && port == other.port
            && username == other.username
            && database == other.database
            && sshEnabled == other.sshEnabled
            && sshConfiguration == other.sshConfiguration
            && sslEnabled == other.sslEnabled
            && sslConfiguration == other.sslConfiguration
            && additionalFields == other.additionalFields
    }
}
