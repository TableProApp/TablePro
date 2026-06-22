import CryptoKit
import Foundation

// MARK: - Table Node

struct ERTableNode: Identifiable, Sendable {
    let id: UUID
    let tableName: String
    let columns: [ERColumnDisplay]
    var displayColumns: [ERColumnDisplay]
    var clusterId: Int?
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
    case manyToOne
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

    static let empty = ERDiagramGraph(nodes: [], edges: [], nodeIndex: [:])
}

// MARK: - Graph Builder

enum ERDiagramGraphBuilder {
    static func build(
        allColumns: [String: [ColumnInfo]],
        allForeignKeys: [String: [ForeignKeyInfo]]
    ) -> ERDiagramGraph {
        var nodeIndex: [String: UUID] = [:]
        var nodes: [ERTableNode] = []

        let fkColumnsByTable: [String: Set<String>] = allForeignKeys.mapValues { fks in
            Set(fks.map(\.column))
        }

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

            nodes.append(ERTableNode(
                id: id,
                tableName: tableName,
                columns: displayColumns,
                displayColumns: displayColumns,
                clusterId: nil
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
                    cardinality: .manyToOne
                ))
            }
        }

        let clusters = ERClusterAnalyzer.assignClusters(nodes: nodes, edges: edges, nodeIndex: nodeIndex)
        let clusteredNodes = nodes.map { node -> ERTableNode in
            var updated = node
            updated.clusterId = clusters[node.id]
            return updated
        }

        return ERDiagramGraph(nodes: clusteredNodes, edges: edges, nodeIndex: nodeIndex)
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
