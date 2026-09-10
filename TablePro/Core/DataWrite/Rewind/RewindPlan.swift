//
//  RewindPlan.swift
//  TablePro
//
//  What restoring a save would do, row by row, decided before anything is written.
//

import Foundation
import TableProPluginKit

enum RewindRowOutcome: Sendable, Equatable {
    /// The row still holds what the save wrote, so it can be put back.
    case willRestore
    /// The row already holds its old values. Restoring it again would be a no-op, which is what
    /// makes a rewind interrupted halfway safe to run again.
    case alreadyRestored
    /// Someone else changed the row since the save. Restoring would throw their work away.
    case changedSinceSave
    /// The row is not there any more.
    case rowMissing
    /// The row is still there, and putting the deleted one back would collide with it.
    case rowAlreadyPresent
    case notReversible(RewindRefusal)

    var restores: Bool {
        if case .willRestore = self { return true }
        return false
    }

    var label: String {
        switch self {
        case .willRestore:
            return String(localized: "Will restore")
        case .alreadyRestored:
            return String(localized: "Already restored")
        case .changedSinceSave:
            return String(localized: "Changed since the save")
        case .rowMissing:
            return String(localized: "Row no longer exists")
        case .rowAlreadyPresent:
            return String(localized: "A row with this key already exists")
        case .notReversible(let refusal):
            return refusal.explanation
        }
    }

    var isSkipped: Bool {
        !restores
    }
}

struct RewindRowPlan: Sendable, Identifiable {
    let id: UUID
    let operation: RowWriteOperation
    let outcome: RewindRowOutcome
    /// The row as the database holds it right now, when it holds one.
    let currentImage: [PluginCellValue]?

    var keyDescription: String {
        let source = operation.preImage ?? operation.postImage ?? []
        let parts = operation.primaryKeyColumns.compactMap { column -> String? in
            guard let index = operation.columns.firstIndex(of: column), index < source.count else { return nil }
            return "\(column)=\(source[index].asText ?? "NULL")"
        }
        return parts.joined(separator: ", ")
    }

    /// What restoring this row does, said the way round the user thinks about it.
    var actionDescription: String {
        switch operation.kind {
        case .update:
            return String(localized: "Restore previous values")
        case .delete:
            return String(localized: "Put the row back")
        case .insert:
            return String(localized: "Remove the added row")
        }
    }
}

struct RewindPlan: Sendable {
    let record: RewindRecord
    let rows: [RewindRowPlan]
    let statements: [ParameterizedStatement]

    var restorableCount: Int {
        rows.count(where: { $0.outcome.restores })
    }

    var skippedCount: Int {
        rows.count(where: \.outcome.isSkipped)
    }

    var canApply: Bool {
        !statements.isEmpty && restorableCount > 0
    }
}
