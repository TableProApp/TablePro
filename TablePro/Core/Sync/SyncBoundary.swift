import Foundation
import TableProSyncTransport

struct SyncBoundary: Equatable, Sendable {
    let includedTypes: Set<SyncRecordType>
    let excludedConnectionIds: Set<UUID>?

    init(includedTypes: Set<SyncRecordType>, excludedConnectionIds: Set<UUID>?) {
        self.includedTypes = includedTypes
        self.excludedConnectionIds = excludedConnectionIds
    }

    init(
        settings: SyncSettings,
        connections: [DatabaseConnection]?,
        ownersKeptOffSync: Set<UUID> = [],
        writableTypes: Set<SyncRecordType> = SyncRecordType.verifiedInProduction
    ) {
        self.init(
            includedTypes: Set(SyncRecordType.allCases.filter { settings.syncs($0) && writableTypes.contains($0) }),
            excludedConnectionIds: connections.map { connections in
                let keptOff = connections.filter { !$0.participatesInSync }.map(\.id)
                return Set(keptOff).union(ownersKeptOffSync.subtracting(connections.map(\.id)))
            }
        )
    }

    var knowsOwners: Bool {
        excludedConnectionIds != nil
    }

    func includes(_ type: SyncRecordType) -> Bool {
        includedTypes.contains(type)
    }

    func includes(_ type: SyncRecordType, owner: UUID?) -> Bool {
        guard includes(type) else { return false }
        guard let owner else { return true }
        guard let excludedConnectionIds else { return false }
        return !excludedConnectionIds.contains(owner)
    }

    func includes(_ tombstone: Tombstone, of type: SyncRecordType) -> Bool {
        includes(type, owner: Self.owner(of: tombstone, type: type))
    }

    static func owner(of tombstone: Tombstone, type: SyncRecordType) -> UUID? {
        tombstone.owner ?? owner(ofRecordId: tombstone.id, type: type)
    }

    static func owner(ofRecordId id: String, type: SyncRecordType) -> UUID? {
        switch type {
        case .settings:
            return FileColumnLayoutPersister.connectionId(ofSyncCategory: id)
        case .connection, .group, .tag, .sshProfile, .credentialProfile,
             .tableFavorite, .favoriteDatabase, .favorite, .favoriteFolder:
            return nil
        }
    }
}
