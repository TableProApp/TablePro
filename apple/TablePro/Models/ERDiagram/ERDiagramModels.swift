import CryptoKit
import Foundation

// MARK: - Table Node

struct ERTableNode: Identifiable, Equatable, Sendable {
    let id: UUID
    let tableName: String
    let columns: [ERColumnDisplay]
    var displayColumns: [ERColumnDisplay]
    var clusterId: Int?
    var isJunctionTable: Bool = false
}

struct ERColumnDisplay: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let dataType: String
    let isPrimaryKey: Bool
    let isForeignKey: Bool
    let isNullable: Bool
    var stagedEdit: ERStagedEdit?
}

enum ERStagedEdit: Sendable, Equatable {
    case added
    case dropped
    case modified
}

// MARK: - Edge

enum ERCardinality: Sendable {
    case oneToOne
    case zeroOrOneToOne
    case manyToOne
    case zeroOrManyToOne
    case manyToMany
}

struct EREdge: Identifiable, Equatable, Sendable {
    let id: UUID
    let fkName: String
    let fromTable: String
    let fromColumn: String
    let toTable: String
    let toColumn: String
    let cardinality: ERCardinality
    var stagedEdit: ERStagedEdit?
}

// MARK: - Graph

struct ERDiagramGraph: Sendable {
    var nodes: [ERTableNode]
    var edges: [EREdge]
    var nodeIndex: [CatalogName: UUID]
    var junctionTableIds: Set<UUID> = []
    var manyToManyEdges: [EREdge] = []

    static let empty = ERDiagramGraph(nodes: [], edges: [], nodeIndex: [:])

    func projected(collapseJunctions: Bool) -> ERDiagramGraph {
        guard collapseJunctions, !junctionTableIds.isEmpty else { return self }

        let visibleNodes = nodes.filter { !junctionTableIds.contains($0.id) }
        let visibleNodeIndex = visibleNodes.reduce(into: [CatalogName: UUID]()) { result, node in
            result[CatalogName(node.tableName)] = node.id
        }
        let visibleEdges = edges.filter { edge in
            guard let fromId = nodeId(of: edge.fromTable), let toId = nodeId(of: edge.toTable) else { return false }
            return !junctionTableIds.contains(fromId) && !junctionTableIds.contains(toId)
        }

        return ERDiagramGraph(
            nodes: visibleNodes,
            edges: visibleEdges + manyToManyEdges,
            nodeIndex: visibleNodeIndex,
            junctionTableIds: junctionTableIds,
            manyToManyEdges: manyToManyEdges
        )
    }

    func nodeId(of table: String) -> UUID? {
        nodeIndex[CatalogName(table)]
    }
}

// MARK: - Graph Builder

enum ERDiagramGraphBuilder {
    static func build(
        allColumns: [CatalogName: [ColumnInfo]],
        allForeignKeys: [CatalogName: [ForeignKeyInfo]],
        allIndexes: [CatalogName: [IndexInfo]] = [:],
        isLocal: (ForeignKeyInfo) -> Bool = { _ in true }
    ) -> ERDiagramGraph {
        let allForeignKeys = ForeignKeyCatalogNames.canonicalized(
            allForeignKeys,
            columns: allColumns.mapValues { $0.map(\.name) }
        )
        // A key into another schema still badges its column, but draws no edge to a same-named local table.
        let localForeignKeys = allForeignKeys.mapValues { $0.filter(isLocal) }
        var nodeIndex: [CatalogName: UUID] = [:]
        var nodes: [ERTableNode] = []

        let fkColumnsByTable: [CatalogName: Set<String>] = allForeignKeys.mapValues { fks in
            Set(fks.map(\.column))
        }
        let columnsByTable: [CatalogName: [String: ColumnInfo]] = allColumns.mapValues { columns in
            Dictionary(columns.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        }
        let uniqueSingleColumnsByTable: [CatalogName: Set<String>] = allColumns.reduce(into: [:]) { result, entry in
            let (tableName, columns) = entry
            var unique: Set<String> = []
            let primaryKeyColumns = columns.filter(\.isPrimaryKey).map(\.name)
            if primaryKeyColumns.count == 1, let only = primaryKeyColumns.first {
                unique.insert(only)
            }
            for index in allIndexes[tableName] ?? []
                where index.isUnique && index.whereClause == nil && index.columns.count == 1 {
                if let column = index.columns.first { unique.insert(column) }
            }
            result[tableName] = unique
        }

        var junctionTableIds: Set<UUID> = []

        for key in allColumns.keys.sorted() {
            let tableName = key.text
            let id = stableId(for: tableName)
            nodeIndex[key] = id

            let columns = allColumns[key] ?? []
            let fkColumns = fkColumnsByTable[key] ?? []

            let displayColumns = columns.map { col in
                ERColumnDisplay(
                    id: "\(tableName).\(col.name)",
                    name: col.name,
                    dataType: col.dataType,
                    isPrimaryKey: col.isPrimaryKey,
                    isForeignKey: fkColumns.contains(col.name),
                    isNullable: col.isNullable
                )
            }

            let isJunction = junctionParents(
                columns: columns,
                foreignKeys: localForeignKeys[key] ?? []
            ) != nil
            if isJunction { junctionTableIds.insert(id) }

            nodes.append(ERTableNode(
                id: id,
                tableName: tableName,
                columns: displayColumns,
                displayColumns: displayColumns,
                clusterId: nil,
                isJunctionTable: isJunction
            ))
        }

        var edges: [EREdge] = []
        var seenFKNames: Set<[CatalogName]> = []

        // Sorted, because a dictionary's order changes per launch and decides port order on ties.
        for key in localForeignKeys.keys.sorted() {
            let tableName = key.text
            for fk in localForeignKeys[key] ?? [] {
                let edgeKey = "\(tableName).\(fk.name).\(fk.column)"
                guard seenFKNames.insert([key, CatalogName(fk.name), CatalogName(fk.column)]).inserted else { continue }

                guard nodeIndex[CatalogName(fk.referencedTable)] != nil else { continue }

                edges.append(EREdge(
                    id: stableId(for: edgeKey),
                    fkName: fk.name,
                    fromTable: tableName,
                    fromColumn: fk.column,
                    toTable: fk.referencedTable,
                    toColumn: fk.referencedColumn,
                    cardinality: inferCardinality(
                        column: columnsByTable[key]?[fk.column],
                        uniqueColumns: uniqueSingleColumnsByTable[key] ?? []
                    )
                ))
            }
        }

        let manyToManyEdges = buildManyToManyEdges(
            allColumns: allColumns,
            allForeignKeys: localForeignKeys,
            nodeIndex: nodeIndex
        )

        let clusters = ERClusterAnalyzer.assignClusters(nodes: nodes, edges: edges, nodeIndex: nodeIndex)
        let clusteredNodes = nodes.map { node -> ERTableNode in
            var updated = node
            updated.clusterId = clusters[node.id]
            return updated
        }

        return ERDiagramGraph(
            nodes: clusteredNodes,
            edges: edges,
            nodeIndex: nodeIndex,
            junctionTableIds: junctionTableIds,
            manyToManyEdges: manyToManyEdges
        )
    }

    private static func inferCardinality(column: ColumnInfo?, uniqueColumns: Set<String>) -> ERCardinality {
        guard let column else { return .zeroOrManyToOne }
        return cardinality(isUnique: uniqueColumns.contains(column.name), isMandatory: !column.isNullable)
    }

    static func cardinality(isUnique: Bool, isMandatory: Bool) -> ERCardinality {
        switch (isUnique, isMandatory) {
        case (true, true): return .oneToOne
        case (true, false): return .zeroOrOneToOne
        case (false, true): return .manyToOne
        case (false, false): return .zeroOrManyToOne
        }
    }

    private static func junctionParents(
        columns: [ColumnInfo],
        foreignKeys: [ForeignKeyInfo]
    ) -> (String, String)? {
        let pkColumns = Set(columns.filter { $0.isPrimaryKey }.map(\.name))
        guard pkColumns.count >= 2 else { return nil }

        let fkColumns = Set(foreignKeys.map(\.column))
        guard pkColumns.isSubset(of: fkColumns) else { return nil }

        var orderedParents: [String] = []
        for fk in foreignKeys where pkColumns.contains(fk.column) {
            if !orderedParents.contains(where: { CatalogName.same($0, fk.referencedTable) }) {
                orderedParents.append(fk.referencedTable)
            }
        }
        guard orderedParents.count == 2 else { return nil }
        return (orderedParents[0], orderedParents[1])
    }

    private static func buildManyToManyEdges(
        allColumns: [CatalogName: [ColumnInfo]],
        allForeignKeys: [CatalogName: [ForeignKeyInfo]],
        nodeIndex: [CatalogName: UUID]
    ) -> [EREdge] {
        var edges: [EREdge] = []
        for key in allColumns.keys.sorted() {
            let tableName = key.text
            guard let (parentA, parentB) = junctionParents(
                columns: allColumns[key] ?? [],
                foreignKeys: allForeignKeys[key] ?? []
            ) else { continue }
            guard nodeIndex[CatalogName(parentA)] != nil, nodeIndex[CatalogName(parentB)] != nil else { continue }

            edges.append(EREdge(
                id: stableId(for: "mn.\(tableName)"),
                fkName: tableName,
                fromTable: parentA,
                fromColumn: "",
                toTable: parentB,
                toColumn: "",
                cardinality: .manyToMany
            ))
        }
        return edges
    }

    static func stableId(for name: String) -> UUID {
        let hash = SHA256.hash(data: Data(name.utf8))
        var bytes = [UInt8](hash.prefix(16))
        // Set UUID version 8 (custom, SHA-256) and variant bits for RFC 4122 compliance
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
