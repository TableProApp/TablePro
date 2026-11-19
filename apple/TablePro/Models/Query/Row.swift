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

// What a few rows carry beyond their values lives in `SparseRowState`, so a row of a million-row result stays small.
struct Row: Equatable, Sendable {
    var id: RowID
    var values: ContiguousArray<PluginCellValue>

    subscript(column: Int) -> PluginCellValue {
        get { column >= 0 && column < values.count ? values[column] : .null }
        set {
            guard column >= 0, column < values.count else { return }
            values[column] = newValue
        }
    }
}

// Keyed by row identity, as `rowLocators` is, so a sort, a value filter or a removal cannot hand one row's state to
// another. A row with none of it has no entry.
struct SparseRowState: Equatable, Sendable {
    // The columns a row has no field for, which only an engine that tells a missing field from NULL reports. Their
    // values read `.null`.
    private(set) var absentColumns: [RowID: Set<Int>] = [:]
    // Column to byte length of a value the page left on the server; it reads `.null` until loaded.
    private(set) var unloadedColumns: [RowID: [Int: Int]] = [:]
    private(set) var exportSnapshots: [RowID: DocumentExportSnapshot] = [:]

    var isEmpty: Bool {
        absentColumns.isEmpty && unloadedColumns.isEmpty && exportSnapshots.isEmpty
    }

    mutating func setAbsentColumns(_ columns: Set<Int>, for id: RowID) {
        Self.set(columns, for: id, in: &absentColumns)
    }

    mutating func setUnloadedColumns(_ columns: [Int: Int], for id: RowID) {
        Self.set(columns, for: id, in: &unloadedColumns)
    }

    mutating func setExportSnapshot(_ snapshot: DocumentExportSnapshot?, for id: RowID) {
        if let snapshot {
            exportSnapshots[id] = snapshot
        } else if !exportSnapshots.isEmpty {
            exportSnapshots.removeValue(forKey: id)
        }
    }

    mutating func setAbsent(_ isAbsent: Bool, column: Int, for id: RowID) {
        var columns = absentColumns[id] ?? []
        if isAbsent {
            columns.insert(column)
        } else {
            columns.remove(column)
        }
        setAbsentColumns(columns, for: id)
    }

    // Whether the column was still waiting on the server.
    mutating func removeUnloadedColumn(_ column: Int, for id: RowID) -> Bool {
        guard var columns = unloadedColumns[id], columns.removeValue(forKey: column) != nil else { return false }
        setUnloadedColumns(columns, for: id)
        return true
    }

    mutating func mapExportSnapshots(_ transform: (DocumentExportSnapshot) -> DocumentExportSnapshot) {
        guard !exportSnapshots.isEmpty else { return }
        exportSnapshots = exportSnapshots.mapValues(transform)
    }

    mutating func removeRow(_ id: RowID) {
        guard !isEmpty else { return }
        absentColumns.removeValue(forKey: id)
        unloadedColumns.removeValue(forKey: id)
        exportSnapshots.removeValue(forKey: id)
    }

    // An empty dictionary answers a lookup without hashing, which is what keeps a result with no sparse state free.
    private static func set<Value: Collection>(_ value: Value, for id: RowID, in table: inout [RowID: Value]) {
        if !value.isEmpty {
            table[id] = value
        } else if !table.isEmpty {
            table.removeValue(forKey: id)
        }
    }
}

/// The original cells let an undo restore document export without assigning types to edited text.
struct DocumentExportSnapshot: Equatable, Sendable {
    var document: PluginExportDocument
    var values: ContiguousArray<PluginCellValue>
    let absentColumns: Set<Int>
    var maskedFields: Set<String> = []

    func document(matching values: ContiguousArray<PluginCellValue>, absentColumns: Set<Int>) -> PluginExportDocument? {
        guard values == self.values, absentColumns == self.absentColumns else { return nil }
        return document
    }
}
