//
//  GridValueFilter.swift
//  TablePro
//

import Foundation

struct ColumnValueFilter: Equatable {
    var selectedValues: Set<String>
    var includesNull: Bool

    var hidesEverything: Bool { selectedValues.isEmpty && !includesNull }
}

struct ColumnDistinctValue: Identifiable, Equatable {
    let display: String
    let isNull: Bool
    let count: Int

    var id: String { isNull ? "\u{0}<null>" : "v:\(display)" }
}

struct GridValueFilterState: Equatable {
    private(set) var filters: [Int: ColumnValueFilter] = [:]
    private(set) var columnNames: [Int: String] = [:]

    var isActive: Bool { !filters.isEmpty }
    var activeColumnCount: Int { filters.count }
    var activeColumns: Set<Int> { Set(filters.keys) }

    func isActive(column dataIndex: Int) -> Bool { filters[dataIndex] != nil }

    func filter(forColumn dataIndex: Int) -> ColumnValueFilter? { filters[dataIndex] }

    mutating func set(_ filter: ColumnValueFilter, columnName: String, forColumn dataIndex: Int) {
        filters[dataIndex] = filter
        columnNames[dataIndex] = columnName
    }

    mutating func clear(column dataIndex: Int) {
        filters.removeValue(forKey: dataIndex)
        columnNames.removeValue(forKey: dataIndex)
    }

    mutating func clearAll() {
        filters.removeAll()
        columnNames.removeAll()
    }

    mutating func prune(againstColumns columns: [String]) {
        for (dataIndex, name) in columnNames where dataIndex >= columns.count || columns[dataIndex] != name {
            filters.removeValue(forKey: dataIndex)
            columnNames.removeValue(forKey: dataIndex)
        }
    }
}
