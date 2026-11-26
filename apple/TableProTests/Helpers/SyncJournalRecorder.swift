import Combine
import Foundation
@testable import TablePro
import TableProSyncTransport

// What a store told its host journal, read the way the previous stable's metadata would hold it: a written record is
// dirty, and a deleted one loses that mark for a tombstone.
@MainActor
final class SyncJournalRecorder {
    let journal = SyncHostJournal()
    private(set) var changes: [SyncHostChange] = []
    private var dirty: [String: Set<String>] = [:]
    private var tombstoned: [String: [String]] = [:]
    private var subscription: AnyCancellable?

    init() {
        subscription = journal.changes.sink { [weak self] change in
            self?.take(change)
        }
    }

    func dirtyIds(for type: SyncRecordType) -> Set<String> {
        dirty[type.coreKind] ?? []
    }

    func tombstones(for type: SyncRecordType) -> [Tombstone] {
        (tombstoned[type.coreKind] ?? []).map { Tombstone(id: $0) }
    }

    func tombstonedIds(for type: SyncRecordType) -> Set<String> {
        Set(tombstoned[type.coreKind] ?? [])
    }

    func clearDirty(type: SyncRecordType) {
        dirty[type.coreKind] = nil
    }

    func clearTombstones(type: SyncRecordType) {
        tombstoned[type.coreKind] = nil
    }

    func clear() {
        changes = []
        dirty = [:]
        tombstoned = [:]
    }

    private func take(_ change: SyncHostChange) {
        changes.append(change)
        dirty[change.kind, default: []].formUnion(change.written)
        dirty[change.kind, default: []].subtract(change.deleted)
        tombstoned[change.kind, default: []] += change.deleted
    }
}
