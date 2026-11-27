import CloudKit
import Foundation
import os
import TableProModels
import TableProSync
import TableProSyncTransport

struct UnreadableCopies: Equatable {
    var connections: Set<UUID> = []
    var groups: Set<UUID> = []
    var tags: Set<UUID> = []
    var projects: Set<UUID> = []

    var isEmpty: Bool {
        connections.isEmpty && groups.isEmpty && tags.isEmpty && projects.isEmpty
    }

    init(connections: Set<UUID> = [], groups: Set<UUID> = [], tags: Set<UUID> = [], projects: Set<UUID> = []) {
        self.connections = connections
        self.groups = groups
        self.tags = tags
        self.projects = projects
    }

    init(recordNames: Set<String>) {
        for name in recordNames {
            guard let parsed = SyncRecordType.parse(recordName: name), let id = UUID(uuidString: parsed.id) else { continue }
            switch parsed.type {
            case .connection: connections.insert(id)
            case .group: groups.insert(id)
            case .tag: tags.insert(id)
            case .project: projects.insert(id)
            default: continue
            }
        }
    }

    var recordNames: Set<String> {
        Set(connections.map { SyncRecordType.connection.recordName(for: $0.uuidString) })
            .union(groups.map { SyncRecordType.group.recordName(for: $0.uuidString) })
            .union(tags.map { SyncRecordType.tag.recordName(for: $0.uuidString) })
            .union(projects.map { SyncRecordType.project.recordName(for: $0.uuidString) })
    }
}

// A record this device stores but cannot read is never re-encoded by it, which would drop what this build cannot read.
// A pulled change to it is held and a build that reads the copy fetches that record by id; a deletion applies by id when
// the record syncs (groups, tags and projects always do), and waits for a build that reads the copy when nothing says.
extension IOSSyncCoordinator {
    private static var unreadableCopiesLogger: Logger {
        Logger(subsystem: "com.TablePro", category: "IOSSyncUnreadableCopies")
    }

    // Owners whose standing is not "syncs" keep their records on the device, both ways.
    func unreadableOwnersKeptOff() -> Set<UUID> {
        unreadableCopies().connections.filter { metadata.standing(ofConnection: $0) != .syncs }
    }

    // A change held while the copy could not be read is fetched by id once it reads: a delta never resends it, and
    // starting the pull over would lose the deletions the delta still carries. A record the fetch does not return
    // stays held, since a missing record and a failed read look the same.
    func recoveringHeldChanges(
        into pulled: PullResult,
        using transport: any IOSSyncTransport
    ) async -> (PullResult, recovered: Set<String>) {
        guard !metadata.changesHeldForUnreadableCopies.isEmpty, let state = getCurrentState?() else { return (pulled, []) }
        let unreadable = unreadableCopies()
        let syncing = UnreadableCopies(
            connections: Set(state.connections.filter(\.participatesInSync).map(\.id))
                .union(unreadable.connections.filter { metadata.standing(ofConnection: $0) != .keptOff }),
            groups: Set(state.groups.map(\.id)).union(unreadable.groups),
            tags: Set(state.tags.map(\.id)).union(unreadable.tags),
            projects: Set((getProjects?() ?? []).map(\.id)).union(unreadable.projects)
        )
        let readable = metadata.readableHeldChanges(syncing: syncing.recordNames, unreadable: unreadable.recordNames)
        let pulledNames = Set(pulled.changedRecords.map(\.recordID.recordName))
        let wanted = readable.subtracting(pulledNames)
        guard !wanted.isEmpty else { return (pulled, readable.intersection(pulledNames)) }
        let zoneID = await transport.currentZoneID
        let ids = wanted.compactMap { name in
            SyncRecordType.parse(recordName: name).map { SyncRecordMapper.recordID(type: $0.type, id: $0.id, in: zoneID) }
        }
        do {
            let fetched = Array(try await transport.fetch(recordIDs: ids).values)
            let merged = PullResult(
                changedRecords: pulled.changedRecords + fetched,
                deletedRecordIDs: pulled.deletedRecordIDs,
                newToken: pulled.newToken,
                unreadRecordIDs: pulled.unreadRecordIDs
            )
            return (merged, readable.intersection(pulledNames).union(fetched.map(\.recordID.recordName)))
        } catch {
            Self.unreadableCopiesLogger.error("Fetching changes held for records that read now failed: \(error.localizedDescription, privacy: .private)")
            return (pulled, readable.intersection(pulledNames))
        }
    }

    // Takes out what the pull carries for copies this device cannot read, and adds the held deletions now due.
    // Returns the held deletions to settle once the pull is saved.
    func settlingUnreadableCopies(_ remote: PullChanges, live: Set<String>) -> (remote: PullChanges, settled: Set<String>) {
        let unreadable = unreadableCopies()
        var kept = remote
        let held = metadata.heldDeletions(live: live, unreadable: unreadable.recordNames)
        let dirty = metadata.dirtyIds(for: .connection)
        for name in held.due {
            guard let parsed = SyncRecordType.parse(recordName: name), parsed.type == .connection,
                  let id = UUID(uuidString: parsed.id), !dirty.contains(parsed.id) else { continue }
            kept.deletedConnectionIDs.insert(id)
        }
        guard !unreadable.isEmpty else { return (kept, held.settled) }

        let changed = UnreadableCopies(
            connections: Set(kept.changedConnections.map(\.id)).intersection(unreadable.connections),
            groups: Set(kept.changedGroups.map(\.id)).intersection(unreadable.groups),
            tags: Set(kept.changedTags.map(\.id)).intersection(unreadable.tags),
            projects: Set(kept.changedProjects.map(\.id)).intersection(unreadable.projects)
        )
        if !changed.isEmpty {
            kept.changedConnections.removeAll { changed.connections.contains($0.id) }
            kept.changedGroups.removeAll { changed.groups.contains($0.id) }
            kept.changedTags.removeAll { changed.tags.contains($0.id) }
            kept.changedProjects.removeAll { changed.projects.contains($0.id) }
            // A copy kept off iCloud never takes a remote change, read or not.
            var held = changed
            held.connections = held.connections.filter { metadata.standing(ofConnection: $0) != .keptOff }
            metadata.changesHeldForUnreadableCopies.formUnion(held.recordNames)
            Self.unreadableCopiesLogger.info("Held pulled changes for records this device cannot read")
        }
        let listed = UnreadableCopies(
            connections: unreadable.connections.filter { live.contains(SyncRecordType.connection.recordName(for: $0.uuidString)) },
            groups: unreadable.groups.filter { live.contains(SyncRecordType.group.recordName(for: $0.uuidString)) },
            tags: unreadable.tags.filter { live.contains(SyncRecordType.tag.recordName(for: $0.uuidString)) },
            projects: unreadable.projects.filter { live.contains(SyncRecordType.project.recordName(for: $0.uuidString)) }
        )

        let deleted = UnreadableCopies(
            connections: metadata.unreadableConnectionsRemoved(
                byDeletionOf: kept.deletedConnectionIDs.intersection(unreadable.connections)
            ),
            groups: kept.deletedGroupIDs.intersection(unreadable.groups),
            tags: kept.deletedTagIDs.intersection(unreadable.tags),
            projects: kept.deletedProjectIDs.intersection(unreadable.projects)
        )
        if !deleted.isEmpty || !listed.isEmpty {
            onUnreadableCopiesSettled?(deleted, listed)
        }
        if !deleted.isEmpty {
            metadata.changesHeldForUnreadableCopies.subtract(deleted.recordNames)
        }
        return (kept, held.settled)
    }
}
