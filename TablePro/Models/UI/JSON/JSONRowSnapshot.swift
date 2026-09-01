//
//  JSONRowSnapshot.swift
//  TablePro
//
//  The selected row, as the JSON inspector needs it.
//

import Foundation
import TableProPluginKit

/// Carries the raw cell values rather than the inspector's formatted strings: the JSON view decides
/// whether a value prints quoted from the column's type, and a string that arrived pre-formatted
/// cannot answer that.
struct JSONRowSnapshot: Equatable, Sendable {
    /// Which row this is. A change here is a new selection, so the reader's expansions go too.
    ///
    /// Everything else is compared by value: the whole snapshot is the change test, because a
    /// hand-written token of the parts that "matter" gets it wrong. One over the cells and the
    /// column names read a late-arriving `columnForeignKeys` as no change at all, so a row selected
    /// before the schema fetch landed kept a tree with no keys to expand until the selection moved.
    let rowIdentity: String
    let columns: [String]
    let columnTypes: [ColumnType]
    let values: [PluginCellValue]
    let foreignKeys: [String: JSONForeignKeyRef]
    /// Carried on the snapshot so the panel can hand it to the view model without the view, which
    /// is what keeps the model in step with the row a render is about to draw.
    let connectionId: UUID
    let databaseType: DatabaseType
}
