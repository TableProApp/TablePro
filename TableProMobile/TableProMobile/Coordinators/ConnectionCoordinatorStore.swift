import Foundation
import Observation
import TableProDatabase
import TableProModels

@MainActor
@Observable
final class ConnectionCoordinatorStore {
    private(set) var generations: [UUID: Int] = [:]

    private var coordinators: [UUID: ConnectionCoordinator] = [:]
    private var removedRecords: [UUID: DatabaseConnection] = [:]
    private var heldRebuilds: [UUID: Bool] = [:]
    private var awaitsEditorRelease = false
    private let editorHolds: EditorHoldRegistry
    private let dropSession: (UUID) -> Void

    init(editorHolds: EditorHoldRegistry, dropSession: @escaping (UUID) -> Void) {
        self.editorHolds = editorHolds
        self.dropSession = dropSession
    }

    convenience init(connectionManager: ConnectionManager, editorHolds: EditorHoldRegistry) {
        self.init(editorHolds: editorHolds) { id in
            Task { await connectionManager.disconnect(id) }
        }
    }

    func generation(for id: UUID) -> Int {
        generations[id, default: 0]
    }

    func coordinator(for connection: DatabaseConnection, appState: AppState) -> ConnectionCoordinator {
        if let existing = coordinators[connection.id] { return existing }
        let created = ConnectionCoordinator(connection: connection, appState: appState)
        created.restorePersistedState()
        coordinators[connection.id] = created
        return created
    }

    func presentedRecord(for id: UUID, in connections: [DatabaseConnection]) -> DatabaseConnection? {
        connections.first { $0.id == id } ?? coordinators[id]?.connection ?? removedRecords[id]
    }

    func discardRemovedRecords() {
        removedRecords.removeAll()
    }

    func invalidate(_ id: UUID, droppingSession: Bool = true) {
        guard editorHolds.isHolding else {
            rebuild(id, droppingSession: droppingSession)
            return
        }
        heldRebuilds[id] = heldRebuilds[id, default: false] || droppingSession
        awaitEditorRelease()
    }

    private func awaitEditorRelease() {
        guard !awaitsEditorRelease else { return }
        awaitsEditorRelease = true
        editorHolds.performWhenReleased { [weak self] in
            self?.runHeldRebuilds()
        }
    }

    private func runHeldRebuilds() {
        awaitsEditorRelease = false
        let released = heldRebuilds
        heldRebuilds.removeAll()
        for (id, droppingSession) in released {
            rebuild(id, droppingSession: droppingSession)
        }
    }

    func reconcile(from old: [DatabaseConnection], to new: [DatabaseConnection]) {
        for change in ConnectionRecordChange.changes(from: old, to: new) {
            switch change {
            case .edited(let record):
                coordinators[record.id]?.adopt(record)
            case .redialed(let record):
                coordinators[record.id]?.adopt(record)
                invalidate(record.id)
            case .removed(let id):
                remove(id)
            }
        }
    }

    private func rebuild(_ id: UUID, droppingSession: Bool) {
        coordinators.removeValue(forKey: id)?.retire()
        generations[id, default: 0] += 1
        guard droppingSession else { return }
        dropSession(id)
    }

    private func remove(_ id: UUID) {
        heldRebuilds[id] = nil
        if let retired = coordinators.removeValue(forKey: id) {
            removedRecords[id] = retired.connection
            retired.retire()
        }
        dropSession(id)
    }
}

nonisolated enum ConnectionRecordChange: Equatable, Sendable {
    case edited(DatabaseConnection)
    case redialed(DatabaseConnection)
    case removed(UUID)

    static func changes(from old: [DatabaseConnection], to new: [DatabaseConnection]) -> [ConnectionRecordChange] {
        let current = Dictionary(new.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen: Set<UUID> = []
        return old.compactMap { previous in
            guard seen.insert(previous.id).inserted else { return nil }
            guard let record = current[previous.id] else { return .removed(previous.id) }
            guard record != previous else { return nil }
            return record.dialsTheSameWay(as: previous) ? .edited(record) : .redialed(record)
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
            && isSample == other.isSample
    }
}
