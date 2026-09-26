//
//  RowWriteCoverage.swift
//  TablePro
//
//  Which pending changes no statement writes.
//
//  A save clears the queue and the undo stack once it commits, so a change that never became a
//  statement is lost the moment the rest of the save succeeds. Every generator, the host's and a
//  driver's, is held to the same rule before anything runs: each pending change is written, or the
//  save is refused and nothing is sent.
//

import Foundation

enum RowWriteCoverage {
    /// Whether a change still has something to write: an update with a cell to set, a row still
    /// marked as inserted, or a row still marked as deleted.
    static func isPending(_ change: RowChange, deletedRowIDs: Set<RowID>, insertedRowIDs: Set<RowID>) -> Bool {
        switch change.type {
        case .update: return !change.cellChanges.isEmpty
        case .insert: return insertedRowIDs.contains(change.rowID)
        case .delete: return deletedRowIDs.contains(change.rowID)
        }
    }

    static func unwrittenChanges(
        _ changes: [RowChange],
        deletedRowIDs: Set<RowID>,
        insertedRowIDs: Set<RowID>,
        writtenRowIDs: Set<RowID>
    ) -> [RowChange] {
        changes.filter { change in
            isPending(change, deletedRowIDs: deletedRowIDs, insertedRowIDs: insertedRowIDs)
                && !writtenRowIDs.contains(change.rowID)
        }
    }
}

/// How many changes of each kind a save could not write, which is what the refusal names.
struct UnwrittenRowCounts: Equatable, Sendable {
    let updates: Int
    let inserts: Int
    let deletes: Int

    init(updates: Int = 0, inserts: Int = 0, deletes: Int = 0) {
        self.updates = updates
        self.inserts = inserts
        self.deletes = deletes
    }

    init(_ changes: [RowChange]) {
        self.init(
            updates: changes.count { $0.type == .update },
            inserts: changes.count { $0.type == .insert },
            deletes: changes.count { $0.type == .delete }
        )
    }

    var isEmpty: Bool { updates == 0 && inserts == 0 && deletes == 0 }

    /// The kind a refusal leads with, in the order the host's messages have always used.
    var leadingKind: RowWriteKind? {
        if updates > 0 { return .update }
        if deletes > 0 { return .delete }
        if inserts > 0 { return .insert }
        return nil
    }

    /// One sentence per kind, naming how many of that kind cannot be written.
    var sentences: [String] {
        var sentences: [String] = []
        if updates > 0 {
            sentences.append(
                updates == 1
                    ? String(localized: "The driver cannot write an edited row.")
                    : String(format: String(localized: "The driver cannot write %lld edited rows."), updates)
            )
        }
        if inserts > 0 {
            sentences.append(
                inserts == 1
                    ? String(localized: "The driver cannot write a new row.")
                    : String(format: String(localized: "The driver cannot write %lld new rows."), inserts)
            )
        }
        if deletes > 0 {
            sentences.append(
                deletes == 1
                    ? String(localized: "The driver cannot delete a row marked for deletion.")
                    : String(format: String(localized: "The driver cannot delete %lld rows marked for deletion."), deletes)
            )
        }
        return sentences
    }
}
