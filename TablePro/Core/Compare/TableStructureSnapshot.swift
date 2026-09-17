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

    /// The same table, said to live somewhere else. A copy reads one namespace and writes another,
    /// and the DDL it generates has to name the one it is writing.
    internal func placed(in schema: String?) -> TableStructureSnapshot {
        guard schema != self.schema else { return self }
        return TableStructureSnapshot(
            name: name,
            schema: schema,
            columns: columns,
            indexes: indexes,
            foreignKeys: foreignKeys,
            engine: engine,
            charset: charset,
            collation: collation
        )
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
            columns: columns.map { EditableColumnDefinition.from(ColumnInfo($0)) },
            indexes: indexes.map { EditableIndexDefinition.from(IndexInfo($0)) },
            foreignKeys: EditableForeignKeyDefinition.grouping(foreignKeys.map(ForeignKeyInfo.init)),
            engine: metadata?.engine,
            charset: nil,
            collation: metadata?.collation
        )
    }
}
