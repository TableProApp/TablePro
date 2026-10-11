import Foundation
import TableProSyncTransport

struct SyncEditSnapshot: Equatable, Sendable {
    static let empty = SyncEditSnapshot(dirty: [], generations: [:])

    let dirty: Set<SyncRecordIdentity>
    let generations: [SyncRecordIdentity: UInt64]

    func dirtyIds(for type: SyncRecordType) -> Set<String> {
        Set(dirty.lazy.filter { $0.type == type }.map(\.id))
    }
}

struct SyncEditGenerations: Sendable {
    private var lastGeneration: UInt64 = 0
    private var generations: [SyncRecordIdentity: UInt64] = [:]

    func generation(of identity: SyncRecordIdentity) -> UInt64 {
        generations[identity] ?? 0
    }

    mutating func recordEdits(of identities: [SyncRecordIdentity]) {
        for identity in identities {
            lastGeneration += 1
            generations[identity] = lastGeneration
        }
    }
}
