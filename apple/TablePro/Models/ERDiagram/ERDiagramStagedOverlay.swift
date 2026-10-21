//
//  ERDiagramStagedOverlay.swift
//  TablePro
//

import Foundation

// An edited table is drawn from its working copy, so an added, dropped or renamed column or key stays on
// the canvas, marked, until the save lands.
enum ERDiagramStagedOverlay {
    struct TableEdits: Sendable, Equatable {
        var columns: [EditableColumnDefinition]
        var foreignKeys: [EditableForeignKeyDefinition]
        var columnEdits: [UUID: ERStagedEdit] = [:]
        var foreignKeyEdits: [UUID: ERStagedEdit] = [:]
        // A key still names a column by the name it had before a staged rename.
        var renamedColumns: [String: String] = [:]
        var uniqueColumns: Set<String> = []

        func displayName(of column: String) -> String {
            renamedColumns[column] ?? column
        }
    }

    static func apply(_ edits: [String: TableEdits], to graph: ERDiagramGraph) -> ERDiagramGraph {
        guard !edits.isEmpty else { return graph }
        var result = graph
        // An edited junction table stays drawn, or collapsing it would hide its staged keys.
        let editedIds = Set(edits.keys.compactMap { graph.nodeIndex[$0] })
        result.junctionTableIds.subtract(editedIds)
        result.manyToManyEdges.removeAll { edits[$0.fkName] != nil }
        result.nodes = graph.nodes.map { node in
            guard let tableEdits = edits[node.tableName] else { return node }
            return overlaid(node, with: tableEdits)
        }

        var baseEdges: [String: EREdge] = [:]
        for edge in graph.edges where baseEdges[edgeKey(edge)] == nil {
            baseEdges[edgeKey(edge)] = edge
        }
        var edges = graph.edges.filter { edits[$0.fromTable] == nil }
        for (table, tableEdits) in edits.sorted(by: { $0.key < $1.key }) {
            edges += overlaidEdges(of: table, with: tableEdits, graph: graph, baseEdges: baseEdges)
        }
        result.edges = edges
        return result
    }

    private static func overlaid(_ node: ERTableNode, with edits: TableEdits) -> ERTableNode {
        let keyColumns = Set(
            edits.foreignKeys
                .filter { edits.foreignKeyEdits[$0.id] != .dropped }
                .flatMap(\.columns)
                .map(edits.displayName(of:))
        )
        let columns = edits.columns.map { column in
            ERColumnDisplay(
                id: "\(node.tableName).\(column.name)",
                name: column.name,
                dataType: column.dataType,
                isPrimaryKey: column.isPrimaryKey,
                isForeignKey: keyColumns.contains(column.name),
                isNullable: column.isNullable,
                stagedEdit: edits.columnEdits[column.id]
            )
        }
        return ERTableNode(
            id: node.id,
            tableName: node.tableName,
            columns: columns,
            displayColumns: columns,
            clusterId: node.clusterId,
            isJunctionTable: node.isJunctionTable
        )
    }

    private static func overlaidEdges(
        of table: String,
        with edits: TableEdits,
        graph: ERDiagramGraph,
        baseEdges: [String: EREdge]
    ) -> [EREdge] {
        let nullability = Dictionary(
            edits.columns.map { ($0.name, $0.isNullable) },
            uniquingKeysWith: { first, _ in first }
        )
        var edges: [EREdge] = []
        for foreignKey in edits.foreignKeys where graph.nodeIndex[foreignKey.referencedTable] != nil {
            let mark = edits.foreignKeyEdits[foreignKey.id]
            for (offset, column) in foreignKey.columns.enumerated() {
                let referenced = foreignKey.referencedColumns.indices.contains(offset)
                    ? foreignKey.referencedColumns[offset]
                    : ""
                let key = "\(table).\(foreignKey.name).\(column)"
                // A key added in place of a dropped one with its name is a separate relationship.
                let base = mark == .added ? nil : baseEdges[key]
                let shown = edits.displayName(of: column)
                edges.append(EREdge(
                    id: base?.id ?? ERDiagramGraphBuilder.stableId(for: "\(key).\(foreignKey.id.uuidString)"),
                    fkName: foreignKey.name,
                    fromTable: table,
                    fromColumn: shown,
                    toTable: foreignKey.referencedTable,
                    toColumn: referenced,
                    cardinality: base?.cardinality ?? ERDiagramGraphBuilder.cardinality(
                        isUnique: edits.uniqueColumns.contains(shown),
                        isMandatory: nullability[shown] == false
                    ),
                    stagedEdit: mark
                ))
            }
        }
        return edges
    }

    private static func edgeKey(_ edge: EREdge) -> String {
        "\(edge.fromTable).\(edge.fkName).\(edge.fromColumn)"
    }
}

extension ERDiagramStagedOverlay.TableEdits {
    @MainActor
    init(_ manager: StructureChangeManager) {
        columns = manager.workingColumns
        foreignKeys = manager.workingForeignKeys
        let keyColumns = manager.workingColumns.filter(\.isPrimaryKey).map(\.name)
        if keyColumns.count == 1, let only = keyColumns.first {
            uniqueColumns.insert(only)
        }
        for index in manager.workingIndexes where index.isUnique && index.whereClause == nil && index.columns.count == 1 {
            uniqueColumns.formUnion(index.columns)
        }
        for change in manager.pendingChanges.values {
            switch change {
            case .addColumn(let column):
                columnEdits[column.id] = .added
            case .modifyColumn(let old, let column):
                columnEdits[column.id] = .modified
                if old.name != column.name {
                    renamedColumns[old.name] = column.name
                }
            case .deleteColumn(let column):
                columnEdits[column.id] = .dropped
            case .addForeignKey(let foreignKey):
                foreignKeyEdits[foreignKey.id] = .added
            case .modifyForeignKey(_, let foreignKey):
                foreignKeyEdits[foreignKey.id] = .modified
            case .deleteForeignKey(let foreignKey):
                foreignKeyEdits[foreignKey.id] = .dropped
            case .addIndex, .modifyIndex, .deleteIndex, .addCheckConstraint, .modifyCheckConstraint,
                 .deleteCheckConstraint, .modifyPrimaryKey, .modifyTableComment:
                continue
            }
        }
    }
}
