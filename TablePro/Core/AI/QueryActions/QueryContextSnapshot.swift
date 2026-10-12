//
//  QueryContextSnapshot.swift
//  TablePro
//

import Foundation

struct QueryContextColumn: Equatable, Sendable {
    let name: String
    let dataType: String
    let isNullable: Bool
    let isPrimaryKey: Bool
    let defaultValue: String?
    let generationExpression: String?
    let comment: String?

    init(
        name: String,
        dataType: String,
        isNullable: Bool,
        isPrimaryKey: Bool,
        defaultValue: String? = nil,
        generationExpression: String? = nil,
        comment: String? = nil
    ) {
        self.name = name
        self.dataType = dataType
        self.isNullable = isNullable
        self.isPrimaryKey = isPrimaryKey
        self.defaultValue = defaultValue
        self.generationExpression = generationExpression
        self.comment = comment
    }

    init(_ column: ColumnInfo) {
        self.init(
            name: column.name,
            dataType: column.dataType,
            isNullable: column.isNullable,
            isPrimaryKey: column.isPrimaryKey,
            defaultValue: column.defaultValue,
            generationExpression: column.generationExpression,
            comment: column.comment
        )
    }
}

struct QueryContextIndex: Equatable, Sendable {
    let name: String
    let columns: [String]
    let isUnique: Bool
    let isPrimary: Bool
    let method: String?
    let predicate: String?
    let includedColumns: [String]
    let isValid: Bool

    init(
        name: String,
        columns: [String],
        isUnique: Bool,
        isPrimary: Bool,
        method: String? = nil,
        predicate: String? = nil,
        includedColumns: [String] = [],
        isValid: Bool = true
    ) {
        self.name = name
        self.columns = columns
        self.isUnique = isUnique
        self.isPrimary = isPrimary
        self.method = method
        self.predicate = predicate
        self.includedColumns = includedColumns
        self.isValid = isValid
    }

    init(_ index: IndexInfo) {
        self.init(
            name: index.name,
            columns: index.columns,
            isUnique: index.isUnique,
            isPrimary: index.isPrimary,
            method: index.type.isEmpty ? nil : index.type,
            predicate: index.whereClause,
            includedColumns: index.includedColumns ?? [],
            isValid: index.isValid
        )
    }
}

struct QueryContextForeignKey: Equatable, Sendable {
    let name: String
    let columns: [String]
    let referencedSchema: String?
    let referencedTable: String
    let referencedColumns: [String]
    let onDelete: String
    let onUpdate: String

    init(
        name: String,
        columns: [String],
        referencedSchema: String? = nil,
        referencedTable: String,
        referencedColumns: [String],
        onDelete: String = "NO ACTION",
        onUpdate: String = "NO ACTION"
    ) {
        self.name = name
        self.columns = columns
        self.referencedSchema = referencedSchema
        self.referencedTable = referencedTable
        self.referencedColumns = referencedColumns
        self.onDelete = onDelete
        self.onUpdate = onUpdate
    }

    static func grouped(_ keys: [ForeignKeyInfo]) -> [QueryContextForeignKey] {
        var order: [String] = []
        var byName: [String: [ForeignKeyInfo]] = [:]
        for key in keys {
            let groupKey = key.name.isEmpty ? "\(key.column)->\(key.referencedTable)" : key.name
            if byName[groupKey] == nil { order.append(groupKey) }
            byName[groupKey, default: []].append(key)
        }
        return order.compactMap { groupKey in
            guard let parts = byName[groupKey], let first = parts.first else { return nil }
            return QueryContextForeignKey(
                name: first.name,
                columns: parts.map(\.column),
                referencedSchema: first.referencedSchema,
                referencedTable: first.referencedTable,
                referencedColumns: parts.map(\.referencedColumn),
                onDelete: first.onDelete,
                onUpdate: first.onUpdate
            )
        }
    }
}

struct QueryContextTableStructure: Equatable, Sendable {
    let columns: [QueryContextColumn]
    let indexes: [QueryContextIndex]
    let indexesUnavailableReason: String?
    let foreignKeys: [QueryContextForeignKey]
    let foreignKeysUnavailableReason: String?
    let approximateRowCount: Int?

    init(
        columns: [QueryContextColumn],
        indexes: [QueryContextIndex] = [],
        indexesUnavailableReason: String? = nil,
        foreignKeys: [QueryContextForeignKey] = [],
        foreignKeysUnavailableReason: String? = nil,
        approximateRowCount: Int? = nil
    ) {
        self.columns = columns
        self.indexes = indexes
        self.indexesUnavailableReason = indexesUnavailableReason
        self.foreignKeys = foreignKeys
        self.foreignKeysUnavailableReason = foreignKeysUnavailableReason
        self.approximateRowCount = approximateRowCount
    }
}

struct QueryContextTable: Equatable, Sendable {
    enum Content: Equatable, Sendable {
        case described(QueryContextTableStructure)
        case unavailable(reason: String)
    }

    let name: String
    let schema: String?
    let kind: TableInfo.TableType?
    let content: Content

    var qualifiedName: String {
        guard let schema, !schema.isEmpty else { return name }
        return "\(schema).\(name)"
    }

    var isUnavailable: Bool {
        if case .unavailable = content { return true }
        return false
    }
}

struct QueryContextSnapshot: Equatable, Sendable {
    let engineName: String
    let languageTag: String
    let serverVersion: String?
    let databaseName: String?
    let schemaName: String?
    let tables: [QueryContextTable]
    let notFound: [String]
    let outsideScope: [String]
    let notDescribed: [String]
    let explainPlan: String?

    init(
        engineName: String,
        languageTag: String = "sql",
        serverVersion: String? = nil,
        databaseName: String? = nil,
        schemaName: String? = nil,
        tables: [QueryContextTable] = [],
        notFound: [String] = [],
        outsideScope: [String] = [],
        notDescribed: [String] = [],
        explainPlan: String? = nil
    ) {
        self.engineName = engineName
        self.languageTag = languageTag
        self.serverVersion = serverVersion
        self.databaseName = databaseName.flatMap { $0.isEmpty ? nil : $0 }
        self.schemaName = schemaName.flatMap { $0.isEmpty ? nil : $0 }
        self.tables = tables
        self.notFound = notFound
        self.outsideScope = outsideScope
        self.notDescribed = notDescribed
        self.explainPlan = explainPlan.flatMap { $0.isEmpty ? nil : $0 }
    }

    var tableNames: [String] {
        tables.map(\.name)
    }

    var unavailableTableNames: [String] {
        tables.filter(\.isUnavailable).map(\.name)
    }
}
