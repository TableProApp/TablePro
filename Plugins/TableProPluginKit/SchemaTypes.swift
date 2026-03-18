//
//  SchemaTypes.swift
//  TableProPluginKit
//
//  Transfer types for DDL schema operations.
//

import Foundation

/// Column definition for plugin DDL generation
public struct PluginColumnDefinition: Sendable {
    public let name: String
    public let dataType: String
    public let isNullable: Bool
    public let defaultValue: String?
    public let isPrimaryKey: Bool
    public let autoIncrement: Bool
    public let comment: String?
    public let unsigned: Bool
    public let onUpdate: String?

    public init(
        name: String,
        dataType: String,
        isNullable: Bool = true,
        defaultValue: String? = nil,
        isPrimaryKey: Bool = false,
        autoIncrement: Bool = false,
        comment: String? = nil,
        unsigned: Bool = false,
        onUpdate: String? = nil
    ) {
        self.name = name
        self.dataType = dataType
        self.isNullable = isNullable
        self.defaultValue = defaultValue
        self.isPrimaryKey = isPrimaryKey
        self.autoIncrement = autoIncrement
        self.comment = comment
        self.unsigned = unsigned
        self.onUpdate = onUpdate
    }
}

/// Index definition for plugin DDL generation
public struct PluginIndexDefinition: Sendable {
    public let name: String
    public let columns: [String]
    public let isUnique: Bool
    public let indexType: String?

    public init(
        name: String,
        columns: [String],
        isUnique: Bool = false,
        indexType: String? = nil
    ) {
        self.name = name
        self.columns = columns
        self.isUnique = isUnique
        self.indexType = indexType
    }
}

/// Foreign key definition for plugin DDL generation
public struct PluginForeignKeyDefinition: Sendable {
    public let name: String
    public let columns: [String]
    public let referencedTable: String
    public let referencedColumns: [String]
    public let onDelete: String
    public let onUpdate: String

    public init(
        name: String,
        columns: [String],
        referencedTable: String,
        referencedColumns: [String],
        onDelete: String = "NO ACTION",
        onUpdate: String = "NO ACTION"
    ) {
        self.name = name
        self.columns = columns
        self.referencedTable = referencedTable
        self.referencedColumns = referencedColumns
        self.onDelete = onDelete
        self.onUpdate = onUpdate
    }
}
