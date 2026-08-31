//
//  MySQLColumnDefinitionSQL.swift
//  MySQLDriverPlugin
//

import Foundation
import TableProPluginKit

internal func mysqlQuoteIdentifier(_ name: String) -> String {
    let escaped = name.replacingOccurrences(of: "`", with: "``")
    return "`\(escaped)`"
}

internal func mysqlEscapeStringLiteral(_ value: String) -> String {
    var result = value
    result = result.replacingOccurrences(of: "\\", with: "\\\\")
    result = result.replacingOccurrences(of: "'", with: "''")
    result = result.replacingOccurrences(of: "\n", with: "\\n")
    result = result.replacingOccurrences(of: "\r", with: "\\r")
    result = result.replacingOccurrences(of: "\t", with: "\\t")
    result = result.replacingOccurrences(of: "\0", with: "\\0")
    result = result.replacingOccurrences(of: "\u{08}", with: "\\b")
    result = result.replacingOccurrences(of: "\u{0C}", with: "\\f")
    result = result.replacingOccurrences(of: "\u{1A}", with: "\\Z")
    return result
}

/// MySQL rejects a CURRENT_TIMESTAMP expression whose fractional-second precision differs
/// from the column's own, so the precision is always taken from the declared type.
internal func mysqlFractionalSecondsSuffix(forDataType dataType: String) -> String {
    let upper = dataType.uppercased()
    guard upper.hasPrefix("TIMESTAMP(") || upper.hasPrefix("DATETIME(") else { return "" }
    guard let open = dataType.firstIndex(of: "("),
          let close = dataType[open...].firstIndex(of: ")") else { return "" }
    return String(dataType[open...close])
}

internal func mysqlCurrentTimestampExpression(_ value: String, dataType: String) -> String? {
    let upper = value.uppercased()
    guard upper == "CURRENT_TIMESTAMP" || upper == "CURRENT_TIMESTAMP()"
        || upper.hasPrefix("CURRENT_TIMESTAMP(") else { return nil }
    return "CURRENT_TIMESTAMP" + mysqlFractionalSecondsSuffix(forDataType: dataType)
}

internal func mysqlDefaultValueLiteral(_ value: String, dataType: String) -> String {
    if let expression = mysqlCurrentTimestampExpression(value, dataType: dataType) { return expression }
    if value.uppercased() == "NULL" || value.hasPrefix("'") { return value }
    if Int64(value) != nil || Double(value) != nil { return value }
    return "'\(mysqlEscapeStringLiteral(value))'"
}

internal func mysqlColumnAttributesSQL(_ column: PluginColumnDefinition) -> String {
    var def = ""

    if column.unsigned {
        def += " UNSIGNED"
    }
    if let charset = column.charset, !charset.isEmpty {
        def += " CHARACTER SET \(charset)"
    }
    if let collation = column.collation, !collation.isEmpty {
        def += " COLLATE \(collation)"
    }
    def += column.isNullable ? " NULL" : " NOT NULL"

    if let defaultValue = column.defaultValue {
        def += " DEFAULT \(mysqlDefaultValueLiteral(defaultValue, dataType: column.dataType))"
    }
    if column.autoIncrement {
        def += " AUTO_INCREMENT"
    }
    if let onUpdate = column.onUpdate,
       let expression = mysqlCurrentTimestampExpression(onUpdate, dataType: column.dataType) {
        def += " ON UPDATE \(expression)"
    }
    if let comment = column.comment, !comment.isEmpty {
        def += " COMMENT '\(mysqlEscapeStringLiteral(comment))'"
    }

    return def
}

internal func mysqlColumnDefinitionSQL(_ column: PluginColumnDefinition) -> String {
    let name = mysqlQuoteIdentifier(column.name)
    guard let expression = column.generationExpression?.nilIfEmpty else {
        return "\(name) \(column.dataType)" + mysqlColumnAttributesSQL(column)
    }
    // A generated column takes the expression in place of the ordinary default and auto-increment
    // attributes, and MySQL rejects most of them alongside it. The keyword is spelled out because
    // both MySQL and MariaDB default to VIRTUAL.
    // Charset and collation belong to the type, so they come before the expression. Leaving them
    // out reset a generated string column to the table defaults, because MODIFY COLUMN replaces
    // the whole definition and a reorder restates it.
    let kind = (column.generationKind ?? .virtual).rawValue
    var definition = "\(name) \(column.dataType)"
    if let charset = column.charset, !charset.isEmpty {
        definition += " CHARACTER SET \(charset)"
    }
    if let collation = column.collation, !collation.isEmpty {
        definition += " COLLATE \(collation)"
    }
    definition += " GENERATED ALWAYS AS (\(expression)) \(kind)"
    if !column.isNullable { definition += " NOT NULL" }
    if let comment = column.comment, !comment.isEmpty {
        definition += " COMMENT '\(mysqlEscapeStringLiteral(comment))'"
    }
    return definition
}
