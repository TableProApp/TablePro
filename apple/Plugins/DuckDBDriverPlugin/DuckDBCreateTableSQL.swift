//
//  DuckDBCreateTableSQL.swift
//  DuckDBDriverPlugin
//

import Foundation
import TableProPluginKit
import TableProSQLGrammar

// The id `DuckDBPlugin.databaseTypeId` holds, for the files iOS compiles without the plugin class.
nonisolated internal let duckdbDatabaseTypeId = "DuckDB"

// Each auto-increment column's sequence first, then the table, its indexes and its column comments. Nil when a
// column or index holds text that is not one type or expression, or a foreign key action DuckDB cannot spell.
nonisolated internal func duckdbCreateTableStatements(
    definition: PluginCreateTableDefinition,
    schema: String,
    quote: (String) -> String
) -> [String]? {
    guard !definition.columns.isEmpty,
          definition.columns.allSatisfy({ duckdbColumnTextRefusal(for: $0) == nil }),
          definition.indexes.allSatisfy({ duckdbIndexExpressionRefusal(for: $0) == nil })
    else { return nil }

    let table = definition.tableName
    let qualifiedTable = "\(quote(schema)).\(quote(table))"
    let pkColumns = definition.columns.filter { $0.isPrimaryKey }
    let inlinePK = pkColumns.count == 1
    var parts: [String] = definition.columns.map {
        duckdbColumnDefinition($0, schema: schema, table: table, inlinePK: inlinePK, inCreateTable: true, quote: quote)
    }

    if pkColumns.count > 1 {
        let pkCols = pkColumns.map { quote($0.name) }.joined(separator: ", ")
        parts.append("PRIMARY KEY (\(pkCols))")
    }

    for fk in definition.foreignKeys {
        guard let foreignKey = duckdbForeignKeyDefinition(fk, quote: quote) else { return nil }
        parts.append(foreignKey)
    }

    let createTable = "CREATE TABLE \(qualifiedTable) (\n  " + parts.joined(separator: ",\n  ") + "\n)"
    let indexStatements = definition.indexes.map {
        DuckDBIndexClauses.createStatement(for: $0, qualifiedTable: qualifiedTable, quote: quote)
    }
    let sequenceStatements = definition.columns.filter(\.autoIncrement).map {
        DuckDBSchemaQueries.createSequenceStatement(
            schema: schema,
            sequence: DuckDBSchemaQueries.autoIncrementSequenceName(table: table, column: $0.name)
        )
    }
    let commentStatements = definition.columns.compactMap { column -> String? in
        guard let comment = column.comment, !comment.isEmpty else { return nil }
        return DuckDBSchemaQueries.columnCommentStatement(
            schema: schema, table: table, column: column.name, comment: comment
        )
    }
    return sequenceStatements + [createTable] + indexStatements + commentStatements
}

// The statements take these as SQL, whether the catalog or the user wrote them.
nonisolated internal func duckdbColumnTextRefusal(name: String, dataType: String, defaultValue: String?) -> String? {
    guard SQLExpressionFragment.isSingleType(dataType, databaseTypeId: duckdbDatabaseTypeId) else {
        return String(format: String(localized: "The type of column %@ cannot be written as SQL."), name)
    }
    if let defaultValue, !SQLExpressionFragment.isSingleExpression(defaultValue, databaseTypeId: duckdbDatabaseTypeId) {
        return String(format: String(localized: "The default of column %@ cannot be written as SQL."), name)
    }
    return nil
}

nonisolated internal func duckdbColumnTextRefusal(for column: PluginColumnDefinition) -> String? {
    duckdbColumnTextRefusal(name: column.name, dataType: column.dataType, defaultValue: column.defaultValue)
}

nonisolated internal func duckdbIndexExpressionRefusal(for index: PluginIndexDefinition) -> String? {
    let expressions = index.expressions ?? []
    guard !expressions.allSatisfy({ SQLExpressionFragment.isSingleExpression($0, databaseTypeId: duckdbDatabaseTypeId) })
    else { return nil }
    return String(format: String(localized: "Index %@ has a key part that is not one SQL expression."), index.name)
}

nonisolated internal func duckdbReferentialAction(_ action: String) -> String? {
    ["NO ACTION", "CASCADE", "SET NULL", "SET DEFAULT", "RESTRICT"].first { $0 == action.uppercased() }
}

// `ADD COLUMN` refuses every constraint, NOT NULL included, so an added auto-increment column carries its default
// alone, and each existing row takes a value from the sequence.
nonisolated internal func duckdbColumnDefinition(
    _ col: PluginColumnDefinition,
    schema: String,
    table: String,
    inlinePK: Bool,
    inCreateTable: Bool,
    quote: (String) -> String
) -> String {
    var def = "\(quote(col.name)) \(col.dataType)"
    if col.autoIncrement {
        if inCreateTable {
            def += " NOT NULL"
        }
        let sequence = DuckDBSchemaQueries.autoIncrementSequenceName(table: table, column: col.name)
        def += " DEFAULT \(DuckDBSchemaQueries.nextvalDefault(schema: schema, sequence: sequence))"
    } else {
        def += col.isNullable ? " NULL" : " NOT NULL"
        if let defaultValue = col.defaultValue {
            def += " DEFAULT \(defaultValue)"
        }
    }
    if inlinePK && col.isPrimaryKey {
        def += " PRIMARY KEY"
    }
    return def
}

nonisolated internal func duckdbForeignKeyDefinition(
    _ fk: PluginForeignKeyDefinition,
    quote: (String) -> String
) -> String? {
    guard let onDelete = duckdbReferentialAction(fk.onDelete), let onUpdate = duckdbReferentialAction(fk.onUpdate)
    else { return nil }
    let cols = fk.columns.map { quote($0) }.joined(separator: ", ")
    let constraint = fk.name.isEmpty ? "" : "CONSTRAINT \(quote(fk.name)) "
    var def = "\(constraint)FOREIGN KEY (\(cols)) REFERENCES \(quote(fk.referencedTable))"
    if !fk.referencedColumns.isEmpty {
        def += " (\(fk.referencedColumns.map { quote($0) }.joined(separator: ", ")))"
    }
    if onDelete != "NO ACTION" {
        def += " ON DELETE \(onDelete)"
    }
    if onUpdate != "NO ACTION" {
        def += " ON UPDATE \(onUpdate)"
    }
    return def
}
