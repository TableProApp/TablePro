//
//  RowMatchPolicy.swift
//  TablePro
//

import Foundation
import TableProPluginKit

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

    /// What a keyless row match compares against for one column, already quoted.
    ///
    /// A keyed match never reaches here: it compares the primary key, which is the one thing the engine guarantees
    /// round-trips. For a keyless match the app has only the value the grid read, and on the types the policy lists
    /// that value does not compare equal to the column, so the server is asked to convert the column first. MySQL
    /// spells that `CONCAT`. SQL Server refuses `=` on `ntext`, `text`, `image` and `xml` (Msg 402) and on
    /// `sql_variant` and spatial types, and compares each exactly once the column is cast to the type the value was
    /// bound as (measured on SQL Server 2022).
    func matchExpression(for column: String, quoted: String, value: PluginCellValue, databaseType: DatabaseType) -> String {
        guard textColumns.contains(column) else { return quoted }
        switch databaseType {
        case .mssql:
            let target = value.asBytes == nil ? "NVARCHAR(MAX)" : "VARBINARY(MAX)"
            return "CAST(\(quoted) AS \(target))"
        default:
            return "CONCAT(\(quoted))"
        }
    }
}
