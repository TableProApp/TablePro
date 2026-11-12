//
//  TableDetailList.swift
//  TablePro
//

import Foundation

/// The per-table lists a sidebar table row can show. Each loads on its own, so opening Columns
/// costs one read and leaves the other lists unread.
enum TableDetailKind: String, CaseIterable, Hashable, Sendable {
    case columns
    case indexes
    case foreignKeys
    case checks
    case triggers
}

/// The groups under a table row: one per detail list, plus the table's partitions. The raw value is
/// saved with a window's open groups, so a case is never renamed.
enum TableDetailGroupKind: String, CaseIterable, Hashable, Sendable {
    case columns
    case indexes
    case foreignKeys
    case checks
    case triggers
    case partitions

    /// Nil for partitions, which the tree reads through its partition lists.
    var detailKind: TableDetailKind? {
        TableDetailKind(rawValue: rawValue)
    }
}

/// One detail list as the driver answered it.
enum TableDetailList: Hashable, Sendable {
    case columns([ColumnInfo])
    case indexes([IndexInfo])
    case foreignKeys([ForeignKeyInfo])
    case checks([CheckConstraintInfo])
    case triggers([TriggerInfo])
}
