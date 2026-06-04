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
    public let charset: String?
    public let collation: String?

    public init(
        name: String,
        dataType: String,
        isNullable: Bool = true,
        defaultValue: String? = nil,
        isPrimaryKey: Bool = false,
        autoIncrement: Bool = false,
        comment: String? = nil,
        unsigned: Bool = false,
        onUpdate: String? = nil,
        charset: String? = nil,
        collation: String? = nil
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
        self.charset = charset
        self.collation = collation
    }
}

/// Index definition for plugin DDL generation
public struct PluginIndexDefinition: Sendable {
    public let name: String
    public let columns: [String]
    public let isUnique: Bool
    public let indexType: String?
    public let columnPrefixes: [String: Int]?
    public let whereClause: String?

    public init(
        name: String,
        columns: [String],
        isUnique: Bool = false,
        indexType: String? = nil,
        columnPrefixes: [String: Int]? = nil,
        whereClause: String? = nil
    ) {
        self.name = name
        self.columns = columns
        self.isUnique = isUnique
        self.indexType = indexType
        self.columnPrefixes = columnPrefixes
        self.whereClause = whereClause
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
    public let referencedSchema: String?

    public init(
        name: String,
        columns: [String],
        referencedTable: String,
        referencedColumns: [String],
        onDelete: String = "NO ACTION",
        onUpdate: String = "NO ACTION",
        referencedSchema: String? = nil
    ) {
        self.name = name
        self.columns = columns
        self.referencedTable = referencedTable
        self.referencedColumns = referencedColumns
        self.onDelete = onDelete
        self.onUpdate = onUpdate
        self.referencedSchema = referencedSchema
    }
}

/// Full table definition for CREATE TABLE DDL generation
public struct PluginCreateTableDefinition: Sendable {
    public let tableName: String
    public let columns: [PluginColumnDefinition]
    public let indexes: [PluginIndexDefinition]
    public let foreignKeys: [PluginForeignKeyDefinition]
    public let primaryKeyColumns: [String]
    public let engine: String?
    public let charset: String?
    public let collation: String?
    public let ifNotExists: Bool

    public init(
        tableName: String,
        columns: [PluginColumnDefinition],
        indexes: [PluginIndexDefinition] = [],
        foreignKeys: [PluginForeignKeyDefinition] = [],
        primaryKeyColumns: [String] = [],
        engine: String? = nil,
        charset: String? = nil,
        collation: String? = nil,
        ifNotExists: Bool = false
    ) {
        self.tableName = tableName
        self.columns = columns
        self.indexes = indexes
        self.foreignKeys = foreignKeys
        self.primaryKeyColumns = primaryKeyColumns
        self.engine = engine
        self.charset = charset
        self.collation = collation
        self.ifNotExists = ifNotExists
    }
}

public enum PluginSQLDDLBuilder {
    public enum ColumnDefaultClausePosition {
        case beforeNullability
        case afterNullability
    }

    public enum ColumnPrimaryKeyClausePosition {
        case afterDataType
        case afterDefaultClause
    }

    public static func columnDefinition(
        _ column: PluginColumnDefinition,
        inlinePrimaryKey: Bool,
        quoteIdentifier: (String) -> String,
        formatDefaultValue: (String) -> String,
        dataTypeSQL: (PluginColumnDefinition) -> String = { $0.dataType },
        postDataTypeSQL: (PluginColumnDefinition) -> String? = { _ in nil },
        emitsNullableKeyword: Bool = true,
        suppressNullability: (PluginColumnDefinition) -> Bool = { _ in false },
        defaultClausePosition: ColumnDefaultClausePosition = .afterNullability,
        primaryKeyClausePosition: ColumnPrimaryKeyClausePosition = .afterDefaultClause,
        primaryKeyClause: String = "PRIMARY KEY",
        postPrimaryKeySQL: (PluginColumnDefinition) -> String? = { _ in nil }
    ) -> String {
        var definition = "\(quoteIdentifier(column.name)) \(dataTypeSQL(column))"
        if let postDataType = postDataTypeSQL(column), !postDataType.isEmpty {
            definition += " \(postDataType)"
        }

        if primaryKeyClausePosition == .afterDataType {
            appendPrimaryKeyClause(
                to: &definition,
                column: column,
                inlinePrimaryKey: inlinePrimaryKey,
                primaryKeyClause: primaryKeyClause,
                postPrimaryKeySQL: postPrimaryKeySQL
            )
        }
        if defaultClausePosition == .beforeNullability {
            appendDefaultClause(to: &definition, column: column, formatDefaultValue: formatDefaultValue)
        }
        if !suppressNullability(column) {
            if column.isNullable {
                if emitsNullableKeyword {
                    definition += " NULL"
                }
            } else {
                definition += " NOT NULL"
            }
        }
        if defaultClausePosition == .afterNullability {
            appendDefaultClause(to: &definition, column: column, formatDefaultValue: formatDefaultValue)
        }
        if primaryKeyClausePosition == .afterDefaultClause {
            appendPrimaryKeyClause(
                to: &definition,
                column: column,
                inlinePrimaryKey: inlinePrimaryKey,
                primaryKeyClause: primaryKeyClause,
                postPrimaryKeySQL: postPrimaryKeySQL
            )
        }

        return definition
    }

    public static func defaultValue(
        _ value: String,
        rawUppercaseValues: Set<String>,
        rawUppercaseSuffixes: [String] = [],
        preservesQuotedStrings: Bool = true,
        allowsNumericLiterals: Bool = true,
        allowsParenthesizedExpressions: Bool = false,
        escapeStringLiteral: (String) -> String
    ) -> String {
        let upper = value.uppercased()

        if rawUppercaseValues.contains(upper) {
            return value
        }
        if rawUppercaseSuffixes.contains(where: { upper.hasSuffix($0) }) {
            return value
        }
        if preservesQuotedStrings, value.hasPrefix("'") {
            return value
        }
        if allowsParenthesizedExpressions, value.hasPrefix("(") {
            return value
        }
        if allowsNumericLiterals, Int64(value) != nil || Double(value) != nil {
            return value
        }

        return "'\(escapeStringLiteral(value))'"
    }

    public static func indexColumnList(
        _ index: PluginIndexDefinition,
        quoteIdentifier: (String) -> String,
        formatColumnSQL: ((String) -> String)? = nil
    ) -> String {
        index.columns.map { column in
            formatColumnSQL?(column) ?? quoteIdentifier(column)
        }.joined(separator: ", ")
    }

    public static func createIndexDefinition(
        _ index: PluginIndexDefinition,
        quoteIdentifier: (String) -> String,
        tableSQL: String?,
        indexKindSQL: ((PluginIndexDefinition) -> String)? = nil,
        indexMethodSQL: ((PluginIndexDefinition) -> String?)? = nil,
        formatColumnSQL: ((String) -> String)? = nil,
        includeWhereClause: Bool = true
    ) -> String {
        let indexKind = indexKindSQL?(index) ?? (index.isUnique ? "UNIQUE INDEX" : "INDEX")
        var definition = "CREATE \(indexKind) \(quoteIdentifier(index.name))"
        if let tableSQL, !tableSQL.isEmpty {
            definition += " ON \(tableSQL)"
        }
        if let method = indexMethodSQL?(index), !method.isEmpty {
            definition += " \(method)"
        }

        let columns = indexColumnList(
            index,
            quoteIdentifier: quoteIdentifier,
            formatColumnSQL: formatColumnSQL
        )
        definition += " (\(columns))"

        if includeWhereClause, let whereClause = index.whereClause, !whereClause.isEmpty {
            definition += " WHERE \(whereClause)"
        }

        return definition
    }

    public static func indexDefinitionFragment(
        _ index: PluginIndexDefinition,
        quoteIdentifier: (String) -> String,
        indexKindSQL: ((PluginIndexDefinition) -> String)? = nil,
        indexMethodSQL: ((PluginIndexDefinition) -> String?)? = nil,
        formatColumnSQL: ((String) -> String)? = nil,
        includeWhereClause: Bool = true
    ) -> String {
        let indexKind = indexKindSQL?(index) ?? (index.isUnique ? "UNIQUE INDEX" : "INDEX")
        let columns = indexColumnList(
            index,
            quoteIdentifier: quoteIdentifier,
            formatColumnSQL: formatColumnSQL
        )

        var definition = "\(indexKind) \(quoteIdentifier(index.name)) (\(columns))"
        if let method = indexMethodSQL?(index), !method.isEmpty {
            definition += " \(method)"
        }
        if includeWhereClause, let whereClause = index.whereClause, !whereClause.isEmpty {
            definition += " WHERE \(whereClause)"
        }

        return definition
    }

    public static func dropIndexDefinition(
        indexName: String,
        quoteIdentifier: (String) -> String,
        qualifiedIndexSQL: String? = nil,
        ifExists: Bool = false,
        tableSQL: String? = nil
    ) -> String {
        var definition = "DROP INDEX"
        if ifExists {
            definition += " IF EXISTS"
        }
        definition += " \(qualifiedIndexSQL ?? quoteIdentifier(indexName))"
        if let tableSQL, !tableSQL.isEmpty {
            definition += " ON \(tableSQL)"
        }
        return definition
    }

    public static func alterTableDropObjectDefinition(
        tableSQL: String,
        objectKind: String,
        objectName: String,
        quoteIdentifier: (String) -> String
    ) -> String {
        "ALTER TABLE \(tableSQL) DROP \(objectKind) \(quoteIdentifier(objectName))"
    }

    public static func alterTableAddColumnDefinition(
        tableSQL: String,
        columnSQL: String,
        addKeyword: String = "ADD COLUMN"
    ) -> String {
        "ALTER TABLE \(tableSQL) \(addKeyword) \(columnSQL)"
    }

    public static func alterTableDropColumnDefinition(
        tableSQL: String,
        columnName: String,
        quoteIdentifier: (String) -> String,
        dropKeyword: String = "DROP COLUMN"
    ) -> String {
        "ALTER TABLE \(tableSQL) \(dropKeyword) \(quoteIdentifier(columnName))"
    }

    public static func alterTableRenameColumnDefinition(
        tableSQL: String,
        oldColumnName: String,
        newColumnName: String,
        quoteIdentifier: (String) -> String,
        renameKeyword: String = "RENAME COLUMN",
        toKeyword: String = "TO"
    ) -> String {
        "ALTER TABLE \(tableSQL) \(renameKeyword) \(quoteIdentifier(oldColumnName)) \(toKeyword) \(quoteIdentifier(newColumnName))"
    }

    public static func primaryKeyColumnList(
        _ columns: [String],
        quoteIdentifier: (String) -> String
    ) -> String {
        columns.map { quoteIdentifier($0) }.joined(separator: ", ")
    }

    public static func modifyPrimaryKeyDefinitions(
        tableSQL: String,
        oldColumns: [String],
        newColumns: [String],
        constraintName: String?,
        quoteIdentifier: (String) -> String,
        dropPrimaryKeyClauseSQL: String? = nil,
        unnamedConstraintSQL: String = "/* unknown constraint */",
        addConstraintNameSQL: String? = nil
    ) -> [String]? {
        var statements: [String] = []
        if !oldColumns.isEmpty {
            if let dropPrimaryKeyClauseSQL, !dropPrimaryKeyClauseSQL.isEmpty {
                statements.append("ALTER TABLE \(tableSQL) \(dropPrimaryKeyClauseSQL)")
            } else {
                let name = constraintName.map { quoteIdentifier($0) } ?? unnamedConstraintSQL
                statements.append("ALTER TABLE \(tableSQL) DROP CONSTRAINT \(name)")
            }
        }

        if !newColumns.isEmpty {
            let columns = primaryKeyColumnList(newColumns, quoteIdentifier: quoteIdentifier)
            var addClause = "ADD"
            if let addConstraintNameSQL, !addConstraintNameSQL.isEmpty {
                addClause += " CONSTRAINT \(addConstraintNameSQL)"
            }
            statements.append("ALTER TABLE \(tableSQL) \(addClause) PRIMARY KEY (\(columns))")
        }

        return statements.isEmpty ? nil : statements
    }

    public static func foreignKeyDefinition(
        _ foreignKey: PluginForeignKeyDefinition,
        quoteIdentifier: (String) -> String,
        includeConstraintName: Bool = true,
        referencedTableSQL: ((PluginForeignKeyDefinition) -> String)? = nil,
        includeOnUpdate: Bool = true,
        normalizeAction: (String) -> String = { $0 }
    ) -> String {
        let columns = foreignKey.columns.map { quoteIdentifier($0) }.joined(separator: ", ")
        let referencedColumns = foreignKey.referencedColumns.map { quoteIdentifier($0) }.joined(separator: ", ")
        let referencedTable = referencedTableSQL?(foreignKey) ?? quoteIdentifier(foreignKey.referencedTable)

        var definition = ""
        if includeConstraintName {
            definition += "CONSTRAINT \(quoteIdentifier(foreignKey.name)) "
        }
        definition += "FOREIGN KEY (\(columns)) REFERENCES \(referencedTable) (\(referencedColumns))"

        let onDelete = normalizeAction(foreignKey.onDelete)
        if onDelete != "NO ACTION" {
            definition += " ON DELETE \(onDelete)"
        }
        let onUpdate = normalizeAction(foreignKey.onUpdate)
        if includeOnUpdate && onUpdate != "NO ACTION" {
            definition += " ON UPDATE \(onUpdate)"
        }

        return definition
    }

    private static func appendDefaultClause(
        to definition: inout String,
        column: PluginColumnDefinition,
        formatDefaultValue: (String) -> String
    ) {
        if let defaultValue = column.defaultValue {
            definition += " DEFAULT \(formatDefaultValue(defaultValue))"
        }
    }

    private static func appendPrimaryKeyClause(
        to definition: inout String,
        column: PluginColumnDefinition,
        inlinePrimaryKey: Bool,
        primaryKeyClause: String,
        postPrimaryKeySQL: (PluginColumnDefinition) -> String?
    ) {
        guard inlinePrimaryKey && column.isPrimaryKey else { return }

        definition += " \(primaryKeyClause)"
        if let postPrimaryKey = postPrimaryKeySQL(column), !postPrimaryKey.isEmpty {
            definition += " \(postPrimaryKey)"
        }
    }
}
