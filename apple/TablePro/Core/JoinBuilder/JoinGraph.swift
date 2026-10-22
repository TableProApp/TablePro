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
    internal let childTable: String
    internal let parentTable: String
    internal let columnPairs: [ColumnPair]

    internal var id: String {
        IdentityPath.joined([childTable, name, parentTable], separator: "|")
    }

    internal func links(_ table: String, to other: String) -> Bool {
        (childTable == table && parentTable == other) || (childTable == other && parentTable == table)
    }

    internal func partner(of table: String) -> String? {
        if childTable == table { return parentTable }
        if parentTable == table { return childTable }
        return nil
    }
}

internal struct JoinStep: Hashable, Sendable {
    internal let table: String
    internal let relationship: JoinRelationship
}

internal struct JoinGraph: Sendable {
    internal let columnsByTable: [String: [String]]
    internal let relationships: [JoinRelationship]
    // A key from a table to itself is left out: it joins nothing between two tables.
    private let relationshipsByTable: [String: [JoinRelationship]]

    internal static let empty = JoinGraph(columnsByTable: [:], relationships: [])

    internal var tableNames: [String] {
        columnsByTable.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    internal init(columnsByTable: [String: [String]], relationships: [JoinRelationship]) {
        self.columnsByTable = columnsByTable
        self.relationships = relationships
        var byTable: [String: [JoinRelationship]] = [:]
        for relationship in relationships where relationship.childTable != relationship.parentTable {
            byTable[relationship.childTable, default: []].append(relationship)
            byTable[relationship.parentTable, default: []].append(relationship)
        }
        relationshipsByTable = byTable
    }

    // A composite key arrives as one row per column under one name. `isLocal` drops a key into another
    // schema, which would otherwise join a same-named table of this one.
    internal init(
        columns: [String: [String]],
        foreignKeys: [String: [ForeignKeyInfo]],
        isLocal: (ForeignKeyInfo) -> Bool
    ) {
        struct KeyIdentity: Hashable {
            let name: String
            let parent: String
        }

        let foreignKeys = ForeignKeyCatalogNames.canonicalized(foreignKeys, columns: columns)
        var relationships: [JoinRelationship] = []
        for childTable in foreignKeys.keys.sorted() where columns[childTable] != nil {
            var order: [KeyIdentity] = []
            var pairsByKey: [KeyIdentity: [JoinRelationship.ColumnPair]] = [:]
            for key in foreignKeys[childTable] ?? [] {
                guard columns[key.referencedTable] != nil, isLocal(key) else { continue }
                let identity = KeyIdentity(name: key.name, parent: key.referencedTable)
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
                    name: identity.name,
                    childTable: childTable,
                    parentTable: identity.parent,
                    columnPairs: pairsByKey[identity] ?? []
                ))
            }
        }
        self.init(columnsByTable: columns, relationships: relationships)
    }

    internal func columns(of table: String) -> [String] {
        columnsByTable[table] ?? []
    }

    internal func relationships(between table: String, and other: String) -> [JoinRelationship] {
        (relationshipsByTable[table] ?? []).filter { $0.partner(of: table) == other }
    }

    // Two tables that only share a parent multiply each other's rows, so that hop costs extra and a
    // junction or a chain of the same length wins.
    internal func path(to table: String, from joined: [String]) -> [JoinStep]? {
        guard !joined.contains(table) else { return [] }
        guard columnsByTable[table] != nil else { return nil }

        struct State: Hashable {
            let table: String
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
