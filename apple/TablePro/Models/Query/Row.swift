//
//  Row.swift
//  TablePro
//

import Foundation
import TableProPluginKit

enum RowID: Hashable, Sendable {
    case existing(Int)
    case inserted(UUID)

    var isInserted: Bool {
        if case .inserted = self { return true }
        return false
    }
}

struct Row: Equatable, Sendable {
    var id: RowID
    var values: ContiguousArray<PluginCellValue>
    /// The columns this row has no field for, which only an engine that tells a missing field from
    /// NULL reports. Their values read `.null`.
    var absentColumns: Set<Int> = []
    // Column to byte length of a value the page left on the server; it reads `.null` until loaded.
    var unloadedColumns: [Int: Int] = [:]
    var exportSnapshot: ExportRowSnapshot?

    func isAbsent(_ column: Int) -> Bool {
        absentColumns.contains(column)
    }

    func unloadedByteCount(_ column: Int) -> Int? {
        unloadedColumns[column]
    }

    var hasUnloadedValues: Bool { !unloadedColumns.isEmpty }

    subscript(column: Int) -> PluginCellValue {
        get { column >= 0 && column < values.count ? values[column] : .null }
        set {
            guard column >= 0, column < values.count else { return }
            values[column] = newValue
        }
    }
}

/// The original cells let an undo restore document export without assigning types to edited text.
struct ExportRowSnapshot: Equatable, Sendable {
    var document: PluginExportDocument
    var values: ContiguousArray<PluginCellValue>
    let absentColumns: Set<Int>
    var maskedFields: Set<String> = []

    func document(matching row: Row) -> PluginExportDocument? {
        guard values == row.values, absentColumns == row.absentColumns else { return nil }
        return document
    }
}
