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
    /// Which row this is. A change here is a new selection, so expansions and fetched keys go.
    let rowIdentity: String
    /// What the row holds. A change here is the same row reloaded, so the tree is rebuilt while
    /// the reader's expansions stay where they were.
    let contentToken: Int
    let columns: [String]
    let columnTypes: [ColumnType]
    let values: [PluginCellValue]
    let foreignKeys: [String: JSONForeignKeyRef]
    /// Carried on the snapshot so the panel can hand it to the view model without the view, which
    /// is what keeps the model in step with the row a render is about to draw.
    let connectionId: UUID
    let databaseType: DatabaseType
}
