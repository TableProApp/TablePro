//
//  TableRows.swift
//  TablePro
//

import Foundation
import TableProPluginKit

struct TableRows: Sendable {
    var rows: ContiguousArray<Row>
    private(set) var indexByID: [RowID: Int]
    var columns: [String]
    var columnTypes: [ColumnType]
    var columnDefaults: [String: String?]
    var columnForeignKeys: [String: ForeignKeyInfo]
    var columnEnumValues: [String: [String]]
    var columnNullable: [String: Bool]

    init(
        rows: ContiguousArray<Row> = [],
        columns: [String] = [],
        columnTypes: [ColumnType] = [],
        columnDefaults: [String: String?] = [:],
        columnForeignKeys: [String: ForeignKeyInfo] = [:],
        columnEnumValues: [String: [String]] = [:],
        columnNullable: [String: Bool] = [:]
    ) {
        self.rows = rows
        self.indexByID = Self.buildIndex(for: rows)
        self.columns = columns
        self.columnTypes = columnTypes
        self.columnDefaults = columnDefaults
        self.columnForeignKeys = columnForeignKeys
        self.columnEnumValues = columnEnumValues
        self.columnNullable = columnNullable
    }

    var count: Int { rows.count }

    func value(at row: Int, column: Int) -> PluginCellValue {
        guard row >= 0, row < rows.count else { return .null }
        return rows[row][column]
    }

    func index(of id: RowID) -> Int? {
        indexByID[id]
    }

    func row(withID id: RowID) -> Row? {
        guard let index = indexByID[id] else { return nil }
        return rows[index]
    }

    @discardableResult
    mutating func edit(row: Int, column: Int, value: PluginCellValue) -> Delta {
        guard row >= 0, row < rows.count else { return .none }
        guard column >= 0, column < columns.count else { return .none }
        guard column < rows[row].values.count else { return .none }
        if rows[row].values[column] == value { return .none }
        rows[row].values[column] = value
        return .cellChanged(row: row, column: column)
    }

    @discardableResult
    mutating func editMany(_ edits: [(row: Int, column: Int, value: PluginCellValue)]) -> Delta {
        var changed: Set<CellPosition> = []
        for edit in edits {
            guard edit.row >= 0, edit.row < rows.count else { continue }
            guard edit.column >= 0, edit.column < columns.count else { continue }
            guard edit.column < rows[edit.row].values.count else { continue }
            if rows[edit.row].values[edit.column] == edit.value { continue }
            rows[edit.row].values[edit.column] = edit.value
            changed.insert(CellPosition(row: edit.row, column: edit.column))
        }
        if changed.isEmpty { return .none }
        return .cellsChanged(changed)
    }

    @discardableResult
    mutating func appendInsertedRow(values: [PluginCellValue]) -> Delta {
        let normalized = Self.normalize(values: values, toCount: columns.count)
        let row = Row(id: .inserted(UUID()), values: normalized)
        let newIndex = rows.count
        rows.append(row)
        indexByID[row.id] = newIndex
        return .rowsInserted(IndexSet(integer: newIndex))
    }

    @discardableResult
    mutating func insertInsertedRow(at index: Int, values: [PluginCellValue]) -> Delta {
        guard index >= 0, index <= rows.count else { return .none }
        let normalized = Self.normalize(values: values, toCount: columns.count)
        let row = Row(id: .inserted(UUID()), values: normalized)
        rows.insert(row, at: index)
        for offset in index..<rows.count {
            indexByID[rows[offset].id] = offset
        }
        return .rowsInserted(IndexSet(integer: index))
    }

    @discardableResult
    mutating func appendPage(_ pageRows: [[PluginCellValue]], startingAt offset: Int) -> Delta {
        guard !pageRows.isEmpty else { return .none }
        let firstIndex = rows.count
        rows.reserveCapacity(rows.count + pageRows.count)
        indexByID.reserveCapacity(indexByID.count + pageRows.count)
        for (idx, values) in pageRows.enumerated() {
            let normalized = Self.normalize(values: values, toCount: columns.count)
            let row = Row(id: .existing(offset + idx), values: normalized)
            let newIndex = firstIndex + idx
            rows.append(row)
            indexByID[row.id] = newIndex
        }
        return .rowsInserted(IndexSet(integersIn: firstIndex...(rows.count - 1)))
    }

    @discardableResult
    mutating func remove(rowIDs: Set<RowID>) -> Delta {
        guard !rowIDs.isEmpty else { return .none }
        var indices = IndexSet()
        for id in rowIDs {
            if let i = indexByID[id] {
                indices.insert(i)
            }
        }
        return removeIndices(indices)
    }

    @discardableResult
    mutating func remove(at indices: IndexSet) -> Delta {
        let valid = indices.filteredIndexSet { $0 >= 0 && $0 < rows.count }
        return removeIndices(valid)
    }

    @discardableResult
    mutating func replace(rows replacementRows: [[PluginCellValue]], offset: Int = 0) -> Delta {
        var rebuilt = ContiguousArray<Row>()
        rebuilt.reserveCapacity(replacementRows.count)
        var rebuiltIndex = [RowID: Int]()
        rebuiltIndex.reserveCapacity(replacementRows.count)
        for (idx, values) in replacementRows.enumerated() {
            let normalized = Self.normalize(values: values, toCount: columns.count)
            let row = Row(id: .existing(offset + idx), values: normalized)
            rebuilt.append(row)
            rebuiltIndex[row.id] = idx
        }
        rows = rebuilt
        indexByID = rebuiltIndex
        return .fullReplace
    }

    @discardableResult
    mutating func updateDisplayMetadata(
        columnTypes: [ColumnType]? = nil,
        columnDefaults: [String: String?]? = nil,
        columnForeignKeys: [String: ForeignKeyInfo]? = nil,
        columnEnumValues: [String: [String]]? = nil,
        columnNullable: [String: Bool]? = nil
    ) -> Delta {
        var didChange = false
        if let columnTypes, columnTypes != self.columnTypes {
            self.columnTypes = columnTypes
            didChange = true
        }
        if let columnDefaults, columnDefaults != self.columnDefaults {
            self.columnDefaults = columnDefaults
            didChange = true
        }
        if let columnForeignKeys, columnForeignKeys != self.columnForeignKeys {
            self.columnForeignKeys = columnForeignKeys
            didChange = true
        }
        if let columnEnumValues, columnEnumValues != self.columnEnumValues {
            self.columnEnumValues = columnEnumValues
            didChange = true
        }
        if let columnNullable, columnNullable != self.columnNullable {
            self.columnNullable = columnNullable
            didChange = true
        }
        return didChange ? .columnsReplaced : .none
    }

    static func from(
        queryRows: [[PluginCellValue]],
        columns: [String],
        columnTypes: [ColumnType],
        columnDefaults: [String: String?] = [:],
        columnForeignKeys: [String: ForeignKeyInfo] = [:],
        columnEnumValues: [String: [String]] = [:],
        columnNullable: [String: Bool] = [:]
    ) -> TableRows {
        var rows = ContiguousArray<Row>()
        rows.reserveCapacity(queryRows.count)
        for (index, values) in queryRows.enumerated() {
            let normalized = normalize(values: values, toCount: columns.count)
            rows.append(Row(id: .existing(index), values: normalized))
        }
        return TableRows(
            rows: rows,
            columns: columns,
            columnTypes: columnTypes,
            columnDefaults: columnDefaults,
            columnForeignKeys: columnForeignKeys,
            columnEnumValues: columnEnumValues,
            columnNullable: columnNullable
        )
    }

    private mutating func removeIndices(_ indices: IndexSet) -> Delta {
        guard !indices.isEmpty else { return .none }
        for index in indices.reversed() {
            let removedID = rows[index].id
            rows.remove(at: index)
            indexByID.removeValue(forKey: removedID)
        }
        if let minRemoved = indices.min(), minRemoved < rows.count {
            for offset in minRemoved..<rows.count {
                indexByID[rows[offset].id] = offset
            }
        }
        return .rowsRemoved(indices)
    }

    private static func normalize(values: [PluginCellValue], toCount targetCount: Int) -> ContiguousArray<PluginCellValue> {
        if values.count == targetCount {
            return ContiguousArray(values)
        }
        var result = ContiguousArray<PluginCellValue>()
        result.reserveCapacity(targetCount)
        if values.count > targetCount {
            result.append(contentsOf: values.prefix(targetCount))
        } else {
            result.append(contentsOf: values)
            result.append(contentsOf: ContiguousArray(repeating: .null, count: targetCount - values.count))
        }
        return result
    }

    private static func buildIndex(for rows: ContiguousArray<Row>) -> [RowID: Int] {
        var index = [RowID: Int]()
        index.reserveCapacity(rows.count)
        for (i, row) in rows.enumerated() {
            index[row.id] = i
        }
        return index
    }
}
