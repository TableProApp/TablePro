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
nonisolated final class SyncHostJournal: Sendable {
    static let shared = SyncHostJournal()

    @MainActor let changes = PassthroughSubject<SyncHostChange, Never>()

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
