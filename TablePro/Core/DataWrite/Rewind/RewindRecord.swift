//
//  RewindRecord.swift
//  TablePro
//
//  One committed save, kept so it can be taken back.
//

import Foundation

struct RewindRecord: Codable, Sendable, Identifiable, Equatable {
    let id: UUID
    /// The query-history row this save produced, when there is one. Provenance only: the record
    /// carries its own connection, table and timestamp so it stays findable after history is
    /// pruned out from under it.
    let historyId: UUID?
    let connectionId: UUID
    let databaseType: DatabaseType
    let target: DataWriteTarget
    let capturedAt: Date
    /// Columns the server computes. They are stripped from a restoring insert exactly as they are
    /// from an ordinary one, so the record has to remember them: the table's schema may have moved
    /// on by the time anyone asks for the rows back.
    let generatedColumns: [String]
    let operations: [RowWriteOperation]

    var reversibleOperations: [RowWriteOperation] {
        operations.filter(\.isReversible)
    }

    var isReversible: Bool {
        !reversibleOperations.isEmpty
    }

    /// The single reason nothing here can be taken back, when every row agrees on one.
    var blanketRefusal: RewindRefusal? {
        guard !operations.isEmpty, reversibleOperations.isEmpty else { return nil }
        let reasons = Set(operations.compactMap(\.refusal))
        return reasons.count == 1 ? reasons.first : nil
    }

    var summary: String {
        let counts = operations.reduce(into: [RowWriteKind: Int]()) { $0[$1.kind, default: 0] += 1 }
        var parts: [String] = []
        if let updated = counts[.update] {
            parts.append(String(format: String(localized: "%d edited"), updated))
        }
        if let inserted = counts[.insert] {
            parts.append(String(format: String(localized: "%d added"), inserted))
        }
        if let deleted = counts[.delete] {
            parts.append(String(format: String(localized: "%d deleted"), deleted))
        }
        return parts.joined(separator: ", ")
    }
}
