//
//  JoinGraph.swift
//  TablePro
//

import Foundation

internal struct JoinRelationship: Hashable, Sendable, Identifiable {
    internal struct ColumnPair: Hashable, Sendable {
        internal let child: String
        internal let parent: String
    }

    internal let name: String
    internal let childTable: CatalogName
    internal let parentTable: CatalogName
    internal let columnPairs: [ColumnPair]

    internal var id: [CatalogName] {
        [childTable, CatalogName(name), parentTable]
    }

    internal func links(_ table: CatalogName, to other: CatalogName) -> Bool {
        (childTable == table && parentTable == other) || (childTable == other && parentTable == table)
    }

    internal func partner(of table: CatalogName) -> CatalogName? {
        if childTable == table { return parentTable }
        if parentTable == table { return childTable }
        return nil
    }
}

internal struct JoinStep: Hashable, Sendable {
    internal let table: CatalogName
    internal let relationship: JoinRelationship
}

// Tables are keyed by name bytes: a schema can hold two tables whose names Swift's String equates.
internal struct JoinGraph: Sendable {
    internal let columnsByTable: [CatalogName: [String]]
    internal let relationships: [JoinRelationship]
    // A key from a table to itself is left out: it joins nothing between two tables.
    private let relationshipsByTable: [CatalogName: [JoinRelationship]]

    internal static let empty = JoinGraph(columnsByTable: [:], relationships: [])

    internal var tableNames: [CatalogName] {
        columnsByTable.keys.sorted { lhs, rhs in
            switch lhs.text.localizedStandardCompare(rhs.text) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: lhs < rhs
            }
        }
    }

    internal init(columnsByTable: [CatalogName: [String]], relationships: [JoinRelationship]) {
        self.columnsByTable = columnsByTable
        self.relationships = relationships
        var byTable: [CatalogName: [JoinRelationship]] = [:]
        for relationship in relationships where relationship.childTable != relationship.parentTable {
            byTable[relationship.childTable, default: []].append(relationship)
            byTable[relationship.parentTable, default: []].append(relationship)
        }
        relationshipsByTable = byTable
    }

    // A composite key arrives as one row per column under one name. `isLocal` drops a key into another
    // schema, which would otherwise join a same-named table of this one.
    internal init(
        columns: [CatalogName: [String]],
        foreignKeys: [CatalogName: [ForeignKeyInfo]],
        isLocal: (ForeignKeyInfo) -> Bool
    ) {
        struct KeyIdentity: Hashable {
            let name: CatalogName
            let parent: CatalogName
        }

        let foreignKeys = ForeignKeyCatalogNames.canonicalized(foreignKeys, columns: columns)
        var relationships: [JoinRelationship] = []
        for childTable in foreignKeys.keys.sorted() where columns[childTable] != nil {
            var order: [KeyIdentity] = []
            var pairsByKey: [KeyIdentity: [JoinRelationship.ColumnPair]] = [:]
            for key in foreignKeys[childTable] ?? [] {
                let parent = CatalogName(key.referencedTable)
                guard columns[parent] != nil, isLocal(key) else { continue }
                let identity = KeyIdentity(name: CatalogName(key.name), parent: parent)
                let pair = JoinRelationship.ColumnPair(child: key.column, parent: key.referencedColumn)
                if pairsByKey[identity] == nil {
                    order.append(identity)
                }
                if pairsByKey[identity]?.contains(pair) != true {
                    pairsByKey[identity, default: []].append(pair)
                }
            }
            for identity in order {
                relationships.append(JoinRelationship(
                    name: identity.name.text,
                    childTable: childTable,
                    parentTable: identity.parent,
                    columnPairs: pairsByKey[identity] ?? []
                ))
            }
        }
        self.init(columnsByTable: columns, relationships: relationships)
    }

    internal func columns(of table: CatalogName) -> [String] {
        columnsByTable[table] ?? []
    }

    internal func relationships(between table: CatalogName, and other: CatalogName) -> [JoinRelationship] {
        (relationshipsByTable[table] ?? []).filter { $0.partner(of: table) == other }
    }

    // Two tables that only share a parent multiply each other's rows, so that hop costs extra and a
    // junction or a chain of the same length wins.
    internal func path(to table: CatalogName, from joined: [CatalogName]) -> [JoinStep]? {
        guard !joined.contains(table) else { return [] }
        guard columnsByTable[table] != nil else { return nil }

        struct State: Hashable {
            let table: CatalogName
            let arrivedAsParent: Bool
        }
        struct Entry {
            let cost: Int
            let order: Int
            let state: State
        }

        let joinedTables = Set(joined)
        var bestCost: [State: Int] = [:]
        var cameFrom: [State: (previous: State, step: JoinStep)] = [:]
        var frontier: [Entry] = []
        var order = 0
        for start in joined {
            let state = State(table: start, arrivedAsParent: false)
            guard bestCost[state] == nil else { continue }
            bestCost[state] = 0
            frontier.append(Entry(cost: 0, order: order, state: state))
            order += 1
        }

        while let index = frontier.indices.min(by: { lhs, rhs in
            (frontier[lhs].cost, frontier[lhs].order) < (frontier[rhs].cost, frontier[rhs].order)
        }) {
            let entry = frontier.remove(at: index)
            guard bestCost[entry.state] == entry.cost else { continue }
            if entry.state.table == table {
                var steps: [JoinStep] = []
                var current = entry.state
                while let link = cameFrom[current] {
                    steps.append(link.step)
                    current = link.previous
                }
                return steps.reversed()
            }
            for relationship in relationshipsByTable[entry.state.table] ?? [] {
                guard let next = relationship.partner(of: entry.state.table), !joinedTables.contains(next) else { continue }
                let leavesForChild = relationship.parentTable == entry.state.table
                let cost = entry.cost + 2 + (entry.state.arrivedAsParent && leavesForChild ? 1 : 0)
                let nextState = State(table: next, arrivedAsParent: relationship.parentTable == next)
                if let known = bestCost[nextState], known <= cost { continue }
                bestCost[nextState] = cost
                cameFrom[nextState] = (entry.state, JoinStep(table: next, relationship: relationship))
                frontier.append(Entry(cost: cost, order: order, state: nextState))
                order += 1
            }
        }
        return nil
    }
}
