//
//  TableRows.swift
//  TablePro
//

import Foundation

struct TableRows: Sendable {
    var rows: ContiguousArray<Row>
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
        self.columns = columns
        self.columnTypes = columnTypes
        self.columnDefaults = columnDefaults
        self.columnForeignKeys = columnForeignKeys
        self.columnEnumValues = columnEnumValues
        self.columnNullable = columnNullable
    }

    var count: Int { rows.count }

    func value(at row: Int, column: Int) -> String? {
        guard row >= 0, row < rows.count else { return nil }
        return rows[row][column]
    }

    func index(of id: RowID) -> Int? {
        for (index, row) in rows.enumerated() where row.id == id {
            return index
        }
        return nil
    }

    func row(withID id: RowID) -> Row? {
        guard let index = index(of: id) else { return nil }
        return rows[index]
    }

    @discardableResult
    mutating func edit(row: Int, column: Int, value: String?) -> Delta {
        guard row >= 0, row < rows.count else { return .none }
        guard column >= 0, column < columns.count else { return .none }
        guard column < rows[row].values.count else { return .none }
        if rows[row].values[column] == value { return .none }
        rows[row].values[column] = value
        return .cellChanged(row: row, column: column)
    }

    @discardableResult
    mutating func editMany(_ edits: [(row: Int, column: Int, value: String?)]) -> Delta {
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
    mutating func appendInsertedRow(values: [String?]) -> Delta {
        let normalized = Self.normalize(values: values, toCount: columns.count)
        let row = Row(id: .inserted(UUID()), values: normalized)
        rows.append(row)
        return .rowsInserted(IndexSet(integer: rows.count - 1))
    }

    @discardableResult
    mutating func insertInsertedRow(at index: Int, values: [String?]) -> Delta {
        guard index >= 0, index <= rows.count else { return .none }
        let normalized = Self.normalize(values: values, toCount: columns.count)
        let row = Row(id: .inserted(UUID()), values: normalized)
        rows.insert(row, at: index)
        return .rowsInserted(IndexSet(integer: index))
    }

    @discardableResult
    mutating func appendPage(_ pageRows: [[String?]], startingAt offset: Int) -> Delta {
        guard !pageRows.isEmpty else { return .none }
        let firstIndex = rows.count
        for (idx, values) in pageRows.enumerated() {
            let normalized = Self.normalize(values: values, toCount: columns.count)
            rows.append(Row(id: .existing(offset + idx), values: normalized))
        }
        let lastIndex = rows.count - 1
        return .rowsInserted(IndexSet(integersIn: firstIndex...lastIndex))
    }

    @discardableResult
    mutating func remove(rowIDs: Set<RowID>) -> Delta {
        guard !rowIDs.isEmpty else { return .none }
        var indices = IndexSet()
        for (index, row) in rows.enumerated() where rowIDs.contains(row.id) {
            indices.insert(index)
        }
        return removeIndices(indices)
    }

    @discardableResult
    mutating func remove(at indices: IndexSet) -> Delta {
        let valid = indices.filteredIndexSet { $0 >= 0 && $0 < rows.count }
        return removeIndices(valid)
    }

    @discardableResult
    mutating func replace(rows replacementRows: [[String?]], offset: Int = 0) -> Delta {
        var rebuilt = ContiguousArray<Row>()
        rebuilt.reserveCapacity(replacementRows.count)
        for (idx, values) in replacementRows.enumerated() {
            let normalized = Self.normalize(values: values, toCount: columns.count)
            rebuilt.append(Row(id: .existing(offset + idx), values: normalized))
        }
        rows = rebuilt
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
        queryRows: [[String?]],
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
            rows.remove(at: index)
        }
        return .rowsRemoved(indices)
    }

    private static func normalize(values: [String?], toCount targetCount: Int) -> [String?] {
        if values.count == targetCount { return values }
        if values.count > targetCount { return Array(values.prefix(targetCount)) }
        return values + Array(repeating: nil, count: targetCount - values.count)
    }
}
