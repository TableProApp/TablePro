//
//  TableStructureSnapshot.swift
//  TablePro
//
//  One side's view of a table's structure, already converted out of plugin
//  transfer types so the diff engine stays free of driver concerns.
//

import Foundation
import TableProPluginKit

internal struct TableStructureSnapshot: Hashable {
    internal let name: String
    internal let schema: String?
    internal let columns: [EditableColumnDefinition]
    internal let indexes: [EditableIndexDefinition]
    internal let foreignKeys: [EditableForeignKeyDefinition]
    internal let engine: String?
    internal let charset: String?
    internal let collation: String?

    internal init(
        name: String,
        schema: String? = nil,
        columns: [EditableColumnDefinition],
        indexes: [EditableIndexDefinition] = [],
        foreignKeys: [EditableForeignKeyDefinition] = [],
        engine: String? = nil,
        charset: String? = nil,
        collation: String? = nil
    ) {
        self.name = name
        self.schema = schema
        self.columns = columns
        self.indexes = indexes
        self.foreignKeys = foreignKeys
        self.engine = engine
        self.charset = charset
        self.collation = collation
    }

    internal var primaryKeyColumns: [String] {
        if let primary = indexes.first(where: { $0.isPrimary }) {
            return primary.columns
        }
        return columns.filter { $0.isPrimaryKey }.map { $0.name }
    }

    internal var qualifiedName: String {
        guard let schema, !schema.isEmpty else { return name }
        return "\(schema).\(name)"
    }
}

internal extension TableStructureSnapshot {
    static func from(
        table: PluginTableInfo,
        columns: [PluginColumnInfo],
        indexes: [PluginIndexInfo],
        foreignKeys: [PluginForeignKeyInfo],
        metadata: PluginTableMetadata? = nil
    ) -> TableStructureSnapshot {
        TableStructureSnapshot(
            name: table.name,
            schema: table.schema,
            columns: columns.map { EditableColumnDefinition.from($0.toColumnInfo()) },
            indexes: indexes.map { EditableIndexDefinition.from($0.toIndexInfo()) },
            foreignKeys: Self.groupForeignKeys(foreignKeys),
            engine: metadata?.engine,
            charset: nil,
            collation: metadata?.collation
        )
    }

    private static func groupForeignKeys(_ foreignKeys: [PluginForeignKeyInfo]) -> [EditableForeignKeyDefinition] {
        var order: [String] = []
        var grouped: [String: [PluginForeignKeyInfo]] = [:]
        for foreignKey in foreignKeys {
            if grouped[foreignKey.name] == nil { order.append(foreignKey.name) }
            grouped[foreignKey.name, default: []].append(foreignKey)
        }
        return order.compactMap { name in
            guard let parts = grouped[name], let first = parts.first else { return nil }
            return EditableForeignKeyDefinition(
                id: UUID(),
                name: name,
                columns: parts.map { $0.column },
                referencedTable: first.referencedTable,
                referencedColumns: parts.map { $0.referencedColumn },
                referencedSchema: first.referencedSchema,
                onDelete: EditableForeignKeyDefinition.ReferentialAction(
                    rawValue: first.onDelete.uppercased()) ?? .noAction,
                onUpdate: EditableForeignKeyDefinition.ReferentialAction(
                    rawValue: first.onUpdate.uppercased()) ?? .noAction
            )
        }
    }
}

private extension PluginColumnInfo {
    func toColumnInfo() -> ColumnInfo {
        ColumnInfo(
            name: name,
            dataType: dataType,
            isNullable: isNullable,
            isPrimaryKey: isPrimaryKey,
            defaultValue: defaultValue,
            extra: extra,
            charset: charset,
            collation: collation,
            comment: comment,
            isGenerated: isGenerated,
            allowedValues: allowedValues,
            generationExpression: generationExpression,
            generationKind: generationKind
        )
    }
}

private extension PluginIndexInfo {
    func toIndexInfo() -> IndexInfo {
        IndexInfo(
            name: name,
            columns: columns,
            isUnique: isUnique,
            isPrimary: isPrimary,
            type: type,
            columnPrefixes: columnPrefixes,
            whereClause: whereClause
        )
    }
}
