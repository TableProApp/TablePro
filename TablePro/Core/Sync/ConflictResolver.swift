//
//  ConflictResolver.swift
//  TablePro
//
//  Queues and resolves sync conflicts one at a time
//

import CloudKit
import Foundation
import Observation
import os

/// Represents a sync conflict between local and remote versions
struct SyncConflict: Identifiable {
    let id: UUID
    let recordType: SyncRecordType
    let entityName: String
    let localRecord: CKRecord
    let serverRecord: CKRecord
    let localModifiedAt: Date
    let serverModifiedAt: Date

    init(
        recordType: SyncRecordType,
        entityName: String,
        localRecord: CKRecord,
        serverRecord: CKRecord,
        localModifiedAt: Date,
        serverModifiedAt: Date
    ) {
        self.id = UUID()
        self.recordType = recordType
        self.entityName = entityName
        self.localRecord = localRecord
        self.serverRecord = serverRecord
        self.localModifiedAt = localModifiedAt
        self.serverModifiedAt = serverModifiedAt
    }
}

/// Manages a queue of sync conflicts for user resolution
@MainActor @Observable
final class ConflictResolver {
    static let shared = ConflictResolver()
    private static let logger = Logger(subsystem: "com.TablePro", category: "ConflictResolver")

    private(set) var pendingConflicts: [SyncConflict] = []

    var hasConflicts: Bool { !pendingConflicts.isEmpty }

    var currentConflict: SyncConflict? { pendingConflicts.first }

    private init() {}

    func addConflict(_ conflict: SyncConflict) {
        pendingConflicts.append(conflict)
        let count = pendingConflicts.count
        Self.logger.trace(
            "Conflict queued: \(conflict.recordType.rawValue)/\(conflict.entityName) (\(count) pending)"
        )
    }

    /// Resolve the current (first) conflict.
    /// Returns the CKRecord to push if keeping local; nil if keeping server version.
    @discardableResult
    func resolveCurrentConflict(keepLocal: Bool) -> CKRecord? {
        guard let conflict = pendingConflicts.first else { return nil }

        pendingConflicts.removeFirst()
        let resolution = keepLocal ? "local" : "server"
        let remaining = pendingConflicts.count
        Self.logger.trace(
            "Resolved conflict: \(conflict.recordType.rawValue)/\(conflict.entityName) — kept \(resolution) (\(remaining) remaining)"
        )

        if keepLocal {
            // Copy local field values onto the server record to update its change tag
            let resolved = conflict.serverRecord
            for key in conflict.localRecord.allKeys() {
                resolved[key] = conflict.localRecord[key]
            }
            return resolved
        }

        return nil
    }
}
