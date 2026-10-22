//
//  JoinQueryDraft.swift
//  TablePro
//

import Foundation

internal enum JoinKind: String, CaseIterable, Identifiable, Sendable {
    case inner
    case left

    internal var id: String { rawValue }

    internal var keyword: String {
        switch self {
        case .inner: "JOIN"
        case .left: "LEFT JOIN"
        }
    }

    internal var displayName: String {
        switch self {
        case .inner: String(localized: "Inner Join")
        case .left: String(localized: "Left Join")
        }
    }
}

internal struct JoinColumnRef: Hashable, Sendable {
    internal let table: String
    internal let column: String
}

internal struct JoinFilter: Identifiable, Equatable, Sendable {
    internal let id: UUID
    internal var column: JoinColumnRef
    internal var filterOperator: FilterOperator
    internal var value: String
    internal var secondValue: String

    internal init(
        id: UUID = UUID(),
        column: JoinColumnRef,
        filterOperator: FilterOperator = .equal,
        value: String = "",
        secondValue: String = ""
    ) {
        self.id = id
        self.column = column
        self.filterOperator = filterOperator
        self.value = value
        self.secondValue = secondValue
    }

    internal var tableFilter: TableFilter {
        TableFilter(
            id: id,
            columnName: column.column,
            filterOperator: filterOperator,
            value: value,
            secondValue: filterOperator.requiresSecondValue ? secondValue : nil,
            isEnabled: true
        )
    }
}

internal struct JoinQueryDraft: Equatable, Sendable {
    internal struct Table: Identifiable, Equatable, Sendable {
        internal let name: String
        internal var kind: JoinKind = .inner
        internal var condition: JoinRelationship?
        internal var selectedColumns: [String] = []

        internal var id: String { name }
    }

    internal private(set) var tables: [Table] = []
    internal var filters: [JoinFilter] = []

    internal var isEmpty: Bool { tables.isEmpty }

    internal func contains(_ table: String) -> Bool {
        tables.contains { $0.name == table }
    }

    internal func index(of table: String) -> Int? {
        tables.firstIndex { $0.name == table }
    }

    internal mutating func add(_ table: String, in graph: JoinGraph) {
        guard !contains(table), graph.columnsByTable[table] != nil else { return }
        guard !tables.isEmpty else {
            tables.append(Table(name: table))
            return
        }
        guard let steps = graph.path(to: table, from: tables.map(\.name)), !steps.isEmpty else {
            tables.append(Table(name: table))
            return
        }
        for step in steps where !contains(step.table) {
            tables.append(Table(name: step.table, condition: step.relationship))
        }
    }

    internal mutating func remove(_ table: String, in graph: JoinGraph) {
        guard let removed = index(of: table) else { return }
        tables.remove(at: removed)
        filters.removeAll { $0.column.table == table }
        relinkConditions(afterRemoving: table, in: graph)
    }

    // A join condition can name only tables already in the FROM clause.
    internal func candidates(forTableAt index: Int, in graph: JoinGraph) -> [JoinRelationship] {
        guard tables.indices.contains(index), index > 0 else { return [] }
        let table = tables[index].name
        return tables[..<index].flatMap { earlier in graph.relationships(between: table, and: earlier.name) }
    }

    internal mutating func setKind(_ kind: JoinKind, forTableAt index: Int) {
        guard tables.indices.contains(index) else { return }
        tables[index].kind = kind
    }

    internal mutating func setCondition(_ condition: JoinRelationship?, forTableAt index: Int, in graph: JoinGraph) {
        guard tables.indices.contains(index), index > 0 else { return }
        guard let condition else {
            tables[index].condition = nil
            return
        }
        guard candidates(forTableAt: index, in: graph).contains(condition) else { return }
        tables[index].condition = condition
    }

    internal func isSelected(_ column: JoinColumnRef) -> Bool {
        tables.first { $0.name == column.table }?.selectedColumns.contains(column.column) ?? false
    }

    internal mutating func setSelected(_ isSelected: Bool, column: JoinColumnRef, in graph: JoinGraph) {
        guard let tableIndex = index(of: column.table) else { return }
        var chosen = Set(tables[tableIndex].selectedColumns)
        if isSelected { chosen.insert(column.column) } else { chosen.remove(column.column) }
        tables[tableIndex].selectedColumns = graph.columns(of: column.table).filter(chosen.contains)
    }

    // Only a join that named the removed table changes; a cross join the user chose stays one.
    private mutating func relinkConditions(afterRemoving removed: String, in graph: JoinGraph) {
        for index in tables.indices {
            guard index > 0 else {
                tables[index].condition = nil
                continue
            }
            guard let condition = tables[index].condition,
                  condition.partner(of: tables[index].name) == removed else { continue }
            tables[index].condition = candidates(forTableAt: index, in: graph).first
        }
    }
}
