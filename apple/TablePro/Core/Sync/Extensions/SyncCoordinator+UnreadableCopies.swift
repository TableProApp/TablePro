import CloudKit
import Foundation
import os
import TableProSyncTransport

// A record this Mac stores but cannot read is never re-encoded by it, which would drop what this build cannot read.
// A pulled change to it is held and a build that reads the copy fetches that record by id; a deletion applies by id
// when the record's standing says it syncs, and waits for a build that reads the copy when nothing says.
extension SyncCoordinator {
    private static let unreadableCopiesLogger = Logger(subsystem: "com.TablePro", category: "SyncUnreadableCopies")

    struct HeldDeletions {
        var due: [CKRecord.ID] = []
        var settled: Set<String> = []
    }

    func unreadableRecordNames() -> Set<String> {
        let connections = services.connectionStorage.unreadableConnectionIds
            .map { SyncRecordType.connection.recordName(for: $0.uuidString) }
        let profiles = services.credentialProfileStorage.unreadableProfileIds
            .map { SyncRecordType.credentialProfile.recordName(for: $0.uuidString) }
        // Groups and tags always sync, so every one this Mac cannot read is listed.
        let groups = services.groupStorage.unreadableGroupIds
            .map { SyncRecordType.group.recordName(for: $0.uuidString) }
        let tags = services.tagStorage.unreadableTagIds
            .map { SyncRecordType.tag.recordName(for: $0.uuidString) }
        return Set(connections + profiles + groups + tags).union(unreadableProjectRecordNames())
    }

    // Empty until projects sync: no pull applies a project before then, so none is held either.
    private func unreadableProjectRecordNames() -> Set<String> {
        guard isProjectSyncWritable() else { return [] }
        return Set(services.projectStorage.unreadableProjectIds.map { SyncRecordType.project.recordName(for: $0.uuidString) })
    }

    struct HeldChangeRecovery {
        var result: PullResult
        var recovered: Set<String> = []
    }

    // Every stored copy that syncs, read or not: Local only connections never take a remote change. Nil while a
    // store cannot be read at all, since its held changes are then neither readable nor gone.
    private func syncingRecordNames() -> Set<String>? {
        let connectionStorage = services.connectionStorage
        let profileStorage = services.credentialProfileStorage
        let readConnections = connectionStorage.loadConnections()
        let readProfiles = profileStorage.loadProfiles()
        let projectStorage = services.projectStorage
        let readProjects = projectStorage.loadProjects()
        let groupStorage = services.groupStorage
        let readGroups = groupStorage.loadGroups()
        let tagStorage = services.tagStorage
        let readTags = tagStorage.loadTags()
        guard !connectionStorage.lastLoadFailed, !profileStorage.lastLoadFailed,
              !projectStorage.storeIsUnreadable, !groupStorage.storeIsUnreadable,
              !tagStorage.storeIsUnreadable else { return nil }
        let connections = readConnections.filter(\.participatesInSync).map(\.id)
            + connectionStorage.unreadableConnectionIds.filter { changeTracker.standing(ofConnection: $0) != .keptOff }
        let profiles = readProfiles.map(\.id) + profileStorage.unreadableProfileIds
        let projects = readProjects.map(\.id) + projectStorage.unreadableProjectIds
        let groups = readGroups.map(\.id) + groupStorage.unreadableGroupIds
        let tags = readTags.map(\.id) + tagStorage.unreadableTagIds
        return Set(connections.map { SyncRecordType.connection.recordName(for: $0.uuidString) })
            .union(profiles.map { SyncRecordType.credentialProfile.recordName(for: $0.uuidString) })
            .union(projects.map { SyncRecordType.project.recordName(for: $0.uuidString) })
            .union(groups.map { SyncRecordType.group.recordName(for: $0.uuidString) })
            .union(tags.map { SyncRecordType.tag.recordName(for: $0.uuidString) })
    }

    // A change held while the copy could not be read is fetched by id once it reads: a delta never resends it, and
    // starting the pull over would lose the deletions the delta still carries. A record the fetch does not return
    // stays held, since a missing record and a failed read look the same.
    func recoveringHeldChanges(
        into result: PullResult,
        zoneID: CKRecordZone.ID,
        fetch: ([CKRecord.ID]) async throws -> [CKRecord.ID: CKRecord]
    ) async -> HeldChangeRecovery {
        guard !metadataStorage.changesHeldForUnreadableCopies.isEmpty,
              let syncing = syncingRecordNames() else { return HeldChangeRecovery(result: result) }
        let readable = metadataStorage.readableHeldChanges(syncing: syncing, unreadable: unreadableRecordNames())
        let pulled = Set(result.changedRecords.map(\.recordID.recordName))
        var recovery = HeldChangeRecovery(result: result, recovered: readable.intersection(pulled))
        let wanted = readable.subtracting(pulled)
        guard !wanted.isEmpty else { return recovery }
        let ids = wanted.compactMap { name in
            SyncRecordType.parse(recordName: name).map { SyncRecordMapper.recordID(type: $0.type, id: $0.id, in: zoneID) }
        }
        do {
            let fetched = Array(try await fetch(ids).values)
            recovery.result = PullResult(
                changedRecords: result.changedRecords + fetched,
                deletedRecordIDs: result.deletedRecordIDs,
                newToken: result.newToken,
                unreadRecordIDs: result.unreadRecordIDs
            )
            recovery.recovered.formUnion(fetched.map(\.recordID.recordName))
        } catch {
            Self.unreadableCopiesLogger.error("Fetching changes held for records that read now failed: \(error.localizedDescription)")
        }
        return recovery
    }

    func settleRecoveredHeldChanges(_ recovered: Set<String>) {
        guard !recovered.isEmpty else { return }
        metadataStorage.changesHeldForUnreadableCopies.subtract(recovered)
    }

    // Then a due deletion follows the rules a readable record does. One of a category this Mac does not sync now
    // stays held, and one edited here since settles unapplied, as a deferred deletion does.
    func heldDeletions(
        dueIn result: PullResult,
        settings: SyncSettings,
        unreadable: Set<String>,
        zoneID: CKRecordZone.ID
    ) -> HeldDeletions {
        // A record the zone listed but this pull could not read is still there, saved after the deletion.
        let live = Set((result.changedRecords.map(\.recordID) + result.unreadRecordIDs).map(\.recordName))
        let held = metadataStorage.heldDeletions(live: live, unreadable: unreadable)
        var deletions = HeldDeletions(settled: held.settled)
        for name in held.due {
            guard let parsed = SyncRecordType.parse(recordName: name) else { continue }
            guard settings.syncs(parsed.type) else {
                deletions.settled.remove(name)
                continue
            }
            guard !changeTracker.dirtyRecords(for: parsed.type).contains(parsed.id) else { continue }
            deletions.due.append(SyncRecordMapper.recordID(type: parsed.type, id: parsed.id, in: zoneID))
        }
        return deletions
    }

    func settleHeldDeletions(_ deletions: HeldDeletions) {
        guard !deletions.settled.isEmpty else { return }
        metadataStorage.deletionsHeldForUnreadableCopies.subtract(deletions.settled)
    }

    func holdChanges(_ recordNames: Set<String>) {
        guard !recordNames.isSubset(of: metadataStorage.changesHeldForUnreadableCopies) else { return }
        metadataStorage.changesHeldForUnreadableCopies.formUnion(recordNames)
        Self.unreadableCopiesLogger.info(
            "Held \(recordNames.count, privacy: .public) pulled changes for records this Mac cannot read"
        )
    }

    func isKeptOffSync(_ recordName: String) -> Bool {
        guard let parsed = SyncRecordType.parse(recordName: recordName), parsed.type == .connection,
              let id = UUID(uuidString: parsed.id) else { return false }
        return changeTracker.standing(ofConnection: id) == .keptOff
    }

    func forgetHeldChanges(ofConnections ids: Set<UUID>) {
        forgetHeldChanges(of: .connection, ids: ids)
    }

    func forgetHeldChanges(of type: SyncRecordType, ids: Set<UUID>) {
        let names = Set(ids.map { type.recordName(for: $0.uuidString) })
        guard !names.isDisjoint(with: metadataStorage.changesHeldForUnreadableCopies) else { return }
        metadataStorage.changesHeldForUnreadableCopies.subtract(names)
    }
}
