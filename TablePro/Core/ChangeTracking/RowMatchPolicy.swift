//
//  RowMatchPolicy.swift
//  TablePro
//

import Foundation

/// How a table without a primary key identifies the row a save is about to write.
///
/// Such a save matches every column against the value the grid read, and the two sets here are the
/// columns that cannot take part in that plainly. They travel together because they are resolved
/// together, from one column list and one engine's metadata: carrying them separately let a path
/// plumb one and forget the other, and a forgotten text set is a save that silently writes nothing.
struct RowMatchPolicy: Equatable, Sendable {
    /// Columns left out of the match entirely, because the engine cannot compare the value at all.
    let excludedColumns: Set<String>

    /// Columns matched through the server's own text rendering rather than the value, because the
    /// text the grid read does not compare equal to what it was read from. See
    /// `PluginMetadataSnapshot.SchemaInfo.rowMatchTextTypePrefixes`.
    let textColumns: Set<String>

    static let none = RowMatchPolicy(excludedColumns: [], textColumns: [])

    init(excludedColumns: Set<String> = [], textColumns: Set<String> = []) {
        self.excludedColumns = excludedColumns
        self.textColumns = textColumns
    }

    var isEmpty: Bool { excludedColumns.isEmpty && textColumns.isEmpty }
}
