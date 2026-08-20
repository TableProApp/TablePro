import CryptoKit
import Foundation

// MARK: - Table Node

struct ERTableNode: Identifiable, Sendable {
    let id: UUID
    let tableName: String
    let columns: [ERColumnDisplay]
    var displayColumns: [ERColumnDisplay]
    var clusterId: Int?
    var isJunctionTable: Bool = false
}

struct ERColumnDisplay: Identifiable, Sendable {
    let id: String
    let name: String
    let dataType: String
    let isPrimaryKey: Bool
    let isForeignKey: Bool
    let isNullable: Bool
}

// MARK: - Edge

enum ERCardinality: Sendable {
    case oneToOne
    case zeroOrOneToOne
    case manyToOne
    case zeroOrManyToOne
    case manyToMany
}

struct EREdge: Identifiable, Sendable {
    let id: UUID
    let fkName: String
    let fromTable: String
    let fromColumn: String
    let toTable: String
    let toColumn: String
    let cardinality: ERCardinality
}

// MARK: - Graph

struct ERDiagramGraph: Sendable {
    var nodes: [ERTableNode]
    var edges: [EREdge]
    var nodeIndex: [String: UUID]
    var junctionTableIds: Set<UUID> = []
    var manyToManyEdges: [EREdge] = []

    static let empty = ERDiagramGraph(nodes: [], edges: [], nodeIndex: [:])

    func projected(collapseJunctions: Bool) -> ERDiagramGraph {
        guard collapseJunctions, !junctionTableIds.isEmpty else { return self }

        let visibleNodes = nodes.filter { !junctionTableIds.contains($0.id) }
        let visibleNodeIndex = visibleNodes.reduce(into: [String: UUID]()) { result, node in
            result[node.tableName] = node.id
        }
        let visibleEdges = edges.filter { edge in
            guard let fromId = nodeIndex[edge.fromTable], let toId = nodeIndex[edge.toTable] else { return false }
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
}

// MARK: - Graph Builder

enum ERDiagramGraphBuilder {
    static func build(
        allColumns: [String: [ColumnInfo]],
        allForeignKeys: [String: [ForeignKeyInfo]],
        allIndexes: [String: [IndexInfo]] = [:]
    ) -> ERDiagramGraph {
        var nodeIndex: [String: UUID] = [:]
        var nodes: [ERTableNode] = []

        let fkColumnsByTable: [String: Set<String>] = allForeignKeys.mapValues { fks in
            Set(fks.map(\.column))
        }
        let columnsByTable: [String: [String: ColumnInfo]] = allColumns.mapValues { columns in
            Dictionary(columns.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        }
        let uniqueSingleColumnsByTable: [String: Set<String>] = allColumns.reduce(into: [:]) { result, entry in
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

        for tableName in allColumns.keys.sorted() {
            let id = stableId(for: tableName)
            nodeIndex[tableName] = id

            let columns = allColumns[tableName] ?? []
            let fkColumns = fkColumnsByTable[tableName] ?? []

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
                tableName: tableName,
                columns: columns,
                foreignKeys: allForeignKeys[tableName] ?? []
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
        var seenFKNames: Set<String> = []

        for (tableName, fks) in allForeignKeys {
            for fk in fks {
                let edgeKey = "\(tableName).\(fk.name).\(fk.column)"
                guard !seenFKNames.contains(edgeKey) else { continue }
                seenFKNames.insert(edgeKey)

                guard nodeIndex[fk.referencedTable] != nil else { continue }

                edges.append(EREdge(
                    id: stableId(for: edgeKey),
                    fkName: fk.name,
                    fromTable: tableName,
                    fromColumn: fk.column,
                    toTable: fk.referencedTable,
                    toColumn: fk.referencedColumn,
                    cardinality: inferCardinality(
                        column: columnsByTable[tableName]?[fk.column],
                        uniqueColumns: uniqueSingleColumnsByTable[tableName] ?? []
                    )
                ))
            }
        }

        let manyToManyEdges = buildManyToManyEdges(
            allColumns: allColumns,
            allForeignKeys: allForeignKeys,
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
        let isUnique = uniqueColumns.contains(column.name)
        let isMandatory = !column.isNullable
        switch (isUnique, isMandatory) {
        case (true, true): return .oneToOne
        case (true, false): return .zeroOrOneToOne
        case (false, true): return .manyToOne
        case (false, false): return .zeroOrManyToOne
        }
    }

    private static func junctionParents(
        tableName: String,
        columns: [ColumnInfo],
        foreignKeys: [ForeignKeyInfo]
    ) -> (String, String)? {
        let pkColumns = Set(columns.filter { $0.isPrimaryKey }.map(\.name))
        guard pkColumns.count >= 2 else { return nil }

        let fkColumns = Set(foreignKeys.map(\.column))
        guard pkColumns.isSubset(of: fkColumns) else { return nil }

        var orderedParents: [String] = []
        for fk in foreignKeys where pkColumns.contains(fk.column) {
            if !orderedParents.contains(fk.referencedTable) {
                orderedParents.append(fk.referencedTable)
            }
        }
        guard orderedParents.count == 2 else { return nil }
        return (orderedParents[0], orderedParents[1])
    }

    private static func buildManyToManyEdges(
        allColumns: [String: [ColumnInfo]],
        allForeignKeys: [String: [ForeignKeyInfo]],
        nodeIndex: [String: UUID]
    ) -> [EREdge] {
        var edges: [EREdge] = []
        for tableName in allColumns.keys.sorted() {
            guard let (parentA, parentB) = junctionParents(
                tableName: tableName,
                columns: allColumns[tableName] ?? [],
                foreignKeys: allForeignKeys[tableName] ?? []
            ) else { continue }
            guard nodeIndex[parentA] != nil, nodeIndex[parentB] != nil else { continue }

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

    private static func stableId(for name: String) -> UUID {
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
