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
    /// The `GENERATED ALWAYS` and SQL Server `IDENTITY` columns among those, which a restore writes back so a deleted
    /// row returns under the key it had. Nil in a record saved before it was kept, which then cannot tell an
    /// allocated key from a computed column.
    let identityColumns: [String]?
    /// The type each column was read as when the save ran, for a driver that writes a restored value through its
    /// column's type. Nil in a record saved before it was kept.
    var columnTypeNames: [String: String]?
    let operations: [RowWriteOperation]
    // Nil in a record saved before views could be edited, and in one that wrote a table.
    var writtenThroughView: Bool?

    var reversibleOperations: [RowWriteOperation] {
        operations.filter { refusal(of: $0) == nil }
    }

    // A deleted row comes back through the view with only the columns it shows. The refusal is
    // decided here, not stored in the operation, so builds that predate the case still read the record.
    func refusal(of operation: RowWriteOperation) -> RewindRefusal? {
        if writtenThroughView == true, operation.kind == .delete { return .deletedThroughView }
        return operation.refusal
    }

    var isReversible: Bool {
        !reversibleOperations.isEmpty
    }

    // Only when every row agrees on one.
    var blanketRefusal: RewindRefusal? {
        guard !operations.isEmpty, reversibleOperations.isEmpty else { return nil }
        let reasons = Set(operations.compactMap(refusal(of:)))
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
