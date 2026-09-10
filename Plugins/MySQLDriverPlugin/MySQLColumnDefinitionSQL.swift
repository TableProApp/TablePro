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

/// MySQL and MariaDB take a `BLOB`, `TEXT`, `JSON` or `GEOMETRY` default "only if the value is
/// written as an expression, even if the expression value is a literal", so the parentheses are
/// required by the grammar rather than chosen by the caller.
internal func mysqlRequiresParenthesisedDefault(dataType: String) -> Bool {
    let upper = dataType.uppercased()
    let base = upper.split(separator: "(", maxSplits: 1).first.map(String.init)?
        .trimmingCharacters(in: .whitespaces) ?? upper
    return base.hasSuffix("BLOB") || base.hasSuffix("TEXT") || base == "JSON" || base == "GEOMETRY"
}

/// Whether the fragment is a literal rather than an expression.
///
/// Under the contract the value already holds the SQL, so the question is answerable by shape: a
/// quoted string, a number, a bit or hex literal, or NULL. Anything else is an expression, and
/// MySQL requires parentheses around every expression default. MariaDB accepts them bare.
internal func mysqlDefaultIsLiteral(_ value: String) -> Bool {
    let upper = value.uppercased()
    if upper == "NULL" || upper == "TRUE" || upper == "FALSE" { return true }
    if upper.hasPrefix("B'") || upper.hasPrefix("X'") || upper.hasPrefix("0X") { return true }
    if Int64(value) != nil || Double(value) != nil { return true }
    return mysqlWholeStringLiteral(value) != nil
}

/// Whether the fragment is one whole single-quoted literal rather than an expression that happens
/// to start with a quote, which `'a' + 'b'` does.
internal func mysqlWholeStringLiteral(_ value: String) -> String? {
    guard value.count >= 2, value.hasPrefix("'"), value.hasSuffix("'") else { return nil }
    let inner = String(value.dropFirst().dropLast())
    var result = ""
    var index = inner.startIndex
    while index < inner.endIndex {
        let character = inner[index]
        let next = inner.index(after: index)
        if character == "\\" {
            guard next < inner.endIndex else { return nil }
            result.append(inner[next])
            index = inner.index(after: next)
            continue
        }
        guard character == "'" else {
            result.append(character)
            index = next
            continue
        }
        guard next < inner.endIndex, inner[next] == "'" else { return nil }
        result.append("'")
        index = inner.index(after: next)
    }
    return result
}

/// The clause the column's `defaultValue` becomes, which is the value itself plus whatever the
/// grammar demands around it.
///
/// Only parentheses and precision are added. `CURRENT_TIMESTAMP` on a temporal column takes that
/// column's own fractional-second precision, because MySQL rejects the pair when they differ, and
/// is the one expression MySQL accepts bare. Every other expression is parenthesised on MySQL,
/// which is what its grammar requires from 8.0.13; MariaDB takes them either way and writes them
/// bare itself. A type that cannot carry a bare default is parenthesised whatever the value is.
///
/// Nothing else is rewritten: the value already holds the SQL, and re-quoting it is what turned
/// `(UUID())` into the six-character string `uuid()`.
internal func mysqlDefaultValueLiteral(_ value: String, dataType: String, isMariaDB: Bool) -> String {
    if mysqlTemporalType(dataType), let expression = mysqlCurrentTimestampExpression(value, dataType: dataType) {
        return expression
    }
    let needsParentheses = mysqlRequiresParenthesisedDefault(dataType: dataType)
        || (!isMariaDB && !mysqlDefaultIsLiteral(value))
    guard needsParentheses else { return value }
    return value.hasPrefix("(") ? value : "(\(value))"
}

/// A column default as the catalog reports it, turned into the SQL that recreates it.
///
/// The two servers report it differently and neither says which it is in the value alone. MySQL
/// leaves a literal bare and marks an expression `DEFAULT_GENERATED` in `EXTRA`. MariaDB from 10.2.7
/// quotes literals and leaves expressions bare, with `EXTRA` empty; before that it quotes nothing,
/// so it reads like MySQL without the marker and every default is a literal.
internal func mysqlDefaultValueFromCatalog(
    _ value: String?,
    extra: String?,
    dataType: String,
    quotesLiterals: Bool
) -> String? {
    guard let value else { return nil }
    if quotesLiterals { return value }

    // MySQL 8.0.13 marks a plain `DEFAULT CURRENT_TIMESTAMP` DEFAULT_GENERATED like any other
    // expression, so this has to be answered before the marker is consulted or the one expression
    // MySQL insists on bare comes back parenthesised.
    if mysqlTemporalType(dataType), mysqlCurrentTimestampExpression(value, dataType: dataType) != nil {
        return value
    }

    guard extra?.uppercased().contains("DEFAULT_GENERATED") != true else {
        return value.hasPrefix("(") ? value : "(\(value))"
    }
    return mysqlCatalogReportsLiteralAsSQL(dataType: dataType)
        ? value : "'\(mysqlEscapeStringLiteral(value))'"
}

/// Whether this column type's catalog default is already the SQL that recreates it.
///
/// A string default comes back stripped of its quotes and has to be given them again. A number, a
/// `BIT` default (`b'1'`) and a binary default (`0x61`) all come back as the literal they are, and
/// quoting one changes what it means: `0x61` quoted stores the four characters rather than the byte.
internal func mysqlCatalogReportsLiteralAsSQL(dataType: String) -> Bool {
    let base = dataType.uppercased().split(separator: "(", maxSplits: 1).first.map(String.init)?
        .trimmingCharacters(in: .whitespaces) ?? dataType.uppercased()
    switch base {
    case "TINYINT", "SMALLINT", "MEDIUMINT", "INT", "INTEGER", "BIGINT",
         "DECIMAL", "DEC", "NUMERIC", "FIXED", "FLOAT", "DOUBLE", "REAL", "YEAR",
         "BIT", "BINARY", "VARBINARY", "BOOL", "BOOLEAN":
        return true
    default:
        return false
    }
}

/// The only types on which a bare `CURRENT_TIMESTAMP` is the temporal expression rather than the
/// seventeen-character string. On a `VARCHAR`, MySQL reports a literal of that text the same way and
/// with no `DEFAULT_GENERATED` marker, so reading it as the expression turns a stored string into a
/// clock reading on the next edit to the column.
internal func mysqlTemporalType(_ dataType: String) -> Bool {
    let base = dataType.uppercased().split(separator: "(", maxSplits: 1).first.map(String.init)?
        .trimmingCharacters(in: .whitespaces) ?? dataType.uppercased()
    return base == "TIMESTAMP" || base == "DATETIME"
}

internal func mysqlColumnAttributesSQL(_ column: PluginColumnDefinition, isMariaDB: Bool) -> String {
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
        def += " DEFAULT \(mysqlDefaultValueLiteral(defaultValue, dataType: column.dataType, isMariaDB: isMariaDB))"
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

internal func mysqlColumnDefinitionSQL(_ column: PluginColumnDefinition, isMariaDB: Bool = false) -> String {
    let name = mysqlQuoteIdentifier(column.name)
    guard let expression = column.generationExpression?.nilIfEmpty else {
        return "\(name) \(column.dataType)" + mysqlColumnAttributesSQL(column, isMariaDB: isMariaDB)
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
