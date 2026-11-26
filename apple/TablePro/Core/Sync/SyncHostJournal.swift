//
//  SyncHostJournal.swift
//  TablePro
//

import Combine
import Foundation
import TableProSyncTransport

// One write of a store the Mac still keeps in Swift: the kind and the ids of the records it saved and removed.
struct SyncHostChange: Equatable, Sendable {
    let kind: String
    let written: [String]
    let deleted: [String]
}

// Each Swift store's write path calls this once its write is on disk (core ADRs 0054 and 0060). The engine's diff, not
// the journal, decides what goes up, so a missed call only delays a push. While the previous stable still runs the
// Swift engine, the engine marks these ids in that build's metadata, so an edit made offline reaches it too.
// Combine's subjects take a send from any thread, and stores journal on the main actor.
nonisolated final class SyncHostJournal: @unchecked Sendable {
    static let shared = SyncHostJournal()

    let changes = PassthroughSubject<SyncHostChange, Never>()

    // An id a write both removed and wrote back is there once it lands, so it counts as written.
    @MainActor
    func recorded(_ type: SyncRecordType, written: [String] = [], deleted: [String] = []) {
        let written = Self.unique(written)
        let writtenIds = Set(written)
        let deleted = Self.unique(deleted).filter { !writtenIds.contains($0) }
        guard !written.isEmpty || !deleted.isEmpty else { return }
        changes.send(SyncHostChange(kind: type.coreKind, written: written, deleted: deleted))
    }

    private static func unique(_ ids: [String]) -> [String] {
        var seen: Set<String> = []
        return ids.filter { seen.insert($0).inserted }
    }
}

// Changes the engine has not taken yet, one entry per kind, each id under the last thing a write did to it.
struct SyncHostChangeQueue: Equatable, Sendable {
    private(set) var changes: [SyncHostChange] = []

    var isEmpty: Bool { changes.isEmpty }

    mutating func append(_ change: SyncHostChange) {
        guard let index = changes.firstIndex(where: { $0.kind == change.kind }) else {
            changes.append(change)
            return
        }
        let pending = changes[index]
        let nowWritten = Set(change.written)
        let nowDeleted = Set(change.deleted)
        changes[index] = SyncHostChange(
            kind: change.kind,
            written: pending.written.filter { !nowWritten.contains($0) && !nowDeleted.contains($0) } + change.written,
            deleted: pending.deleted.filter { !nowWritten.contains($0) && !nowDeleted.contains($0) } + change.deleted
        )
    }

    // Changes that came before the ones queued now, such as a batch the engine refused, go back ahead of them.
    mutating func putBack(_ older: [SyncHostChange]) {
        var queue = SyncHostChangeQueue()
        for change in older + changes {
            queue.append(change)
        }
        self = queue
    }

    mutating func takeAll() -> [SyncHostChange] {
        defer { changes = [] }
        return changes
    }
}

extension SyncRecordType {
    // The core's kind for the record type iCloud carries it as (`tablepro-records`, the CloudKit registry).
    var coreKind: String {
        switch self {
        case .connection: "connection"
        case .group: "group"
        case .tag: "tag"
        case .settings: "macos_settings"
        case .favorite: "saved_query"
        case .favoriteFolder: "saved_query_folder"
        case .tableFavorite: "favourite_table"
        case .favoriteDatabase: "favourite_database"
        case .sshProfile: "ssh_profile"
        case .credentialProfile: "credential_profile"
        case .tableFolder: "table_folder"
        case .tableFolderItem: "table_folder_item"
        }
    }
}
