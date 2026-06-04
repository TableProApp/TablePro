//
//  DesktopSyncConflictResolver.swift
//  TablePro
//
//  Queues and resolves sync conflicts one at a time
//

import CloudKit
import Foundation
import Observation
import os
import TableProSync

/// Manages a queue of sync conflicts for user resolution
@MainActor @Observable
final class DesktopSyncConflictResolver {
    static let shared = DesktopSyncConflictResolver()
    private static let logger = Logger(subsystem: "com.TablePro", category: "DesktopSyncConflictResolver")

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
