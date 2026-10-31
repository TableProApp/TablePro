//
//  MySQLColumnDefinitionSQL.swift
//  MySQLDriverPlugin
//

import Foundation
import TableProMySQLCore
import TableProPluginKit

internal func mysqlQuoteIdentifier(_ name: String) -> String {
    let escaped = name.replacingOccurrences(of: "`", with: "``")
    return "`\(escaped)`"
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
/// bare itself. A type that cannot carry a bare default is parenthesised whatever the value is, with
/// one exception: `NULL`. Every type takes it bare, and parenthesised it is no longer the literal:
/// MySQL 8 stores `DEFAULT (NULL)` as an expression default and MySQL 5.7 refuses the syntax.
///
/// Nothing else is rewritten: the value already holds the SQL, and re-quoting it is what turned
/// `(UUID())` into the six-character string `uuid()`.
internal func mysqlDefaultValueLiteral(_ value: String, dataType: String, isMariaDB: Bool) -> String {
    if mysqlIsNullLiteral(value) { return "NULL" }
    if mysqlTemporalType(dataType), let expression = mysqlCurrentTimestampExpression(value, dataType: dataType) {
        return expression
    }
    let needsParentheses = mysqlRequiresParenthesisedDefault(dataType: dataType)
        || (!isMariaDB && !mysqlDefaultIsLiteral(value))
    guard needsParentheses else { return value }
    return value.hasPrefix("(") ? value : "(\(value))"
}

internal func mysqlIsNullLiteral(_ value: String) -> Bool {
    value.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("NULL") == .orderedSame
}

/// Which of `CHARACTER SET` and `COLLATE` a column type takes. Measured on MySQL 8.4 and MariaDB 11.4:
/// `CHARACTER SET` on `INT`, `VARBINARY`, `BLOB` or `JSON` is ERROR 1064, and so is `CHARACTER SET` on a
/// national spelling (`NVARCHAR`), which takes `COLLATE` alone. A type outside the list takes neither.
internal enum MySQLColumnTextType: Equatable {
    case none
    case collationOnly
    case characterSetAndCollation

    init(dataType: String) {
        let words = dataType.uppercased()
            .prefix { $0 != "(" }
            .split(whereSeparator: \.isWhitespace)
        guard let first = words.first else {
            self = .none
            return
        }
        let second = words.dropFirst().first
        switch first {
        case "NATIONAL", "NCHAR", "NVARCHAR":
            self = .collationOnly
        case "CHAR", "CHARACTER":
            self = second == "BYTE" ? .none : .characterSetAndCollation
        case "LONG":
            self = second == "VARBINARY" ? .none : .characterSetAndCollation
        case "VARCHAR", "VARCHARACTER", "TINYTEXT", "TEXT", "MEDIUMTEXT", "LONGTEXT", "ENUM", "SET":
            self = .characterSetAndCollation
        default:
            self = .none
        }
    }

    var takesCharacterSet: Bool { self == .characterSetAndCollation }
    var takesCollation: Bool { self != .none }
}

/// A name the catalog lists is a bare word; anything else is backticked, so the server refuses it as
/// unknown rather than reading the rest of it as SQL.
internal func mysqlCharsetName(_ name: String) -> String {
    mysqlIsSafeCharsetIdentifier(name) ? name : mysqlQuoteIdentifier(name)
}

internal func mysqlIsSafeCharsetIdentifier(_ value: String) -> Bool {
    guard !value.isEmpty else { return false }
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
    return value.unicodeScalars.allSatisfy { allowed.contains($0) }
}

internal func mysqlCharacterSetClauses(_ column: PluginColumnDefinition) -> String {
    let textType = MySQLColumnTextType(dataType: column.dataType)
    var clauses = ""
    if textType.takesCharacterSet, let charset = column.charset?.nilIfEmpty {
        clauses += " CHARACTER SET \(mysqlCharsetName(charset))"
    }
    if textType.takesCollation, let collation = column.collation?.nilIfEmpty {
        clauses += " COLLATE \(mysqlCharsetName(collation))"
    }
    return clauses
}

internal func mysqlColumnAttributesSQL(_ column: PluginColumnDefinition, isMariaDB: Bool) -> String {
    var def = ""

    if column.unsigned {
        def += " UNSIGNED"
    }
    def += mysqlCharacterSetClauses(column)
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

/// `columnCheck` is the column's own `CHECK` as the statement restates it, printed last on the line as
/// MariaDB prints it. Only a `MODIFY` or a move of a column that already has one passes it.
internal func mysqlColumnDefinitionSQL(
    _ column: PluginColumnDefinition,
    isMariaDB: Bool = false,
    columnCheck: String? = nil
) -> String {
    let check = columnCheck?.nilIfEmpty.map { " CHECK (\($0))" } ?? ""
    return mysqlColumnBodySQL(column, isMariaDB: isMariaDB) + check
}

private func mysqlColumnBodySQL(_ column: PluginColumnDefinition, isMariaDB: Bool) -> String {
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
    var definition = "\(name) \(column.dataType)" + mysqlCharacterSetClauses(column)
    definition += " GENERATED ALWAYS AS (\(expression)) \(kind)"
    if !column.isNullable { definition += " NOT NULL" }
    if let comment = column.comment, !comment.isEmpty {
        definition += " COMMENT '\(mysqlEscapeStringLiteral(comment))'"
    }
    return definition
}
