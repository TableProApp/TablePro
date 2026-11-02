//
//  MySQLCatalogDefault.swift
//  MySQLDriverPlugin
//
//  A column default as the catalog reports it, turned into the SQL that recreates it.
//

import Foundation
import TableProMySQLCore
import TableProPluginKit
import TableProSQLGrammar
import TableProSQLQuoting

/// A catalog default, tagged with the form the read that produced it uses.
///
/// Nothing in the value alone says which form it is in, and the two forms disagree on what SQL NULL
/// and a bare word mean, so the form travels with the value rather than as a flag beside it.
nonisolated internal enum MySQLCatalogDefault: Equatable, Sendable {
    /// `SHOW FULL COLUMNS` on every server, and `INFORMATION_SCHEMA.COLUMNS` on MySQL and on MariaDB
    /// before 10.2.7. A literal arrives unquoted, MySQL marks an expression `DEFAULT_GENERATED` in
    /// `EXTRA`, and SQL NULL stands for both `DEFAULT NULL` and no default at all.
    case bare(String?)

    /// `INFORMATION_SCHEMA.COLUMNS` on MariaDB from 10.2.7. A literal arrives quoted, an expression
    /// bare, `DEFAULT NULL` as the unquoted text `NULL`, and SQL NULL only for no default. MariaDB's
    /// `SHOW FULL COLUMNS` does not follow it: measured on 12.3, it reports `'abc'` as `abc` and
    /// `uuid()` as `uuid()` with an empty `EXTRA`.
    case quoted(String?)

    var value: String? {
        switch self {
        case .bare(let value), .quoted(let value): value
        }
    }
}

/// The column defaults `SHOW CREATE TABLE` states, and which columns a column read takes them for.
nonisolated internal struct MySQLCreateTableDefaults: Equatable, Sendable {
    enum Scope: Equatable, Sendable {
        /// A MariaDB whose catalog did not answer in its quoted form: the statement is the only exact
        /// source, for every column. A column with no `DEFAULT` clause there has none.
        case everyColumn
        /// MySQL: only the expression defaults its catalog cannot report exactly. Every other default
        /// reads better from the catalog, where a number stays `5` rather than the `'5'` this prints.
        case expressionDefaults
    }

    let clauses: [String: String]
    let scope: Scope

    func catalogDefault(forColumn name: String, extra: String?) -> MySQLCatalogDefault? {
        switch scope {
        case .everyColumn:
            return .quoted(clauses[name])
        case .expressionDefaults:
            guard mysqlIsExpressionDefault(extra: extra), let clause = clauses[name] else { return nil }
            return .quoted(clause)
        }
    }
}

// SQL NULL is `DEFAULT NULL` on a nullable column (#3058), and a generated or AUTO_INCREMENT column takes no default.
nonisolated internal func mysqlColumnDefault(
    _ catalog: MySQLCatalogDefault,
    extra: String?,
    dataType: String,
    isNullable: Bool,
    banner: String? = nil,
    flavor: MySQLServerFlavor = .mysql
) -> String? {
    guard !mysqlColumnIsGenerated(extra: extra), mysqlIdentityKind(extra: extra) == nil else { return nil }
    guard let value = catalog.value else { return isNullable ? "NULL" : nil }
    guard case .bare = catalog else { return mysqlCatalogExpression(value, flavor: flavor) }
    return mysqlBareCatalogDefault(value, extra: extra, dataType: dataType, banner: banner, flavor: flavor)
}

// The quoted catalog first, then `SHOW CREATE TABLE`, then the row's own bare value.
nonisolated internal func mysqlShowColumnsDefault(
    _ shown: String?,
    catalog: MySQLCatalogDefault?,
    createTable: MySQLCreateTableDefaults?,
    column: String,
    extra: String?,
    dataType: String,
    isNullable: Bool,
    banner: String? = nil,
    flavor: MySQLServerFlavor = .mysql
) -> String? {
    mysqlColumnDefault(
        catalog ?? createTable?.catalogDefault(forColumn: column, extra: extra) ?? .bare(shown),
        extra: extra,
        dataType: dataType,
        isNullable: isNullable,
        banner: banner,
        flavor: flavor
    )
}

nonisolated private func mysqlBareCatalogDefault(
    _ value: String,
    extra: String?,
    dataType: String,
    banner: String?,
    flavor: MySQLServerFlavor
) -> String {
    // MySQL 8.0.13 marks a plain `DEFAULT CURRENT_TIMESTAMP` DEFAULT_GENERATED, and that one has to stay bare.
    if mysqlTemporalType(dataType), mysqlCurrentTimestampExpression(value, dataType: dataType) != nil {
        return mysqlCatalogExpression(value, flavor: flavor)
    }
    if mysqlIsExpressionDefault(extra: extra) {
        let expression = mysqlUnescapedCatalogExpression(value)
        return mysqlCatalogExpression(expression.hasPrefix("(") ? expression : "(\(expression))", flavor: flavor)
    }
    return mysqlCatalogReportsLiteralAsSQL(value, dataType: dataType, banner: banner, flavor: flavor)
        ? value : SQLQuoting.stringLiteral(value, escapes: .mysql)
}

// Catalog text that is not one expression goes in as the string it holds, which cannot end the clause it lands in.
nonisolated private func mysqlCatalogExpression(_ text: String, flavor: MySQLServerFlavor) -> String {
    mysqlIsSingleExpression(text, flavor: flavor) ? text : SQLQuoting.stringLiteral(text, escapes: .mysql)
}

// The server prints it with backslash escapes whatever the session, and a NO_BACKSLASH_ESCAPES session gets it respelled.
nonisolated internal func mysqlIsSingleExpression(_ text: String, flavor: MySQLServerFlavor) -> Bool {
    let printed = SQLLexicalProfile.curated(forDatabaseTypeId: flavor.databaseTypeId)?.readings
        .filter { $0.contains(.backslashEscapesInSingleQuotes) } ?? []
    let respelled = printed.map { $0.subtracting([.backslashEscapesInSingleQuotes, .backslashEscapesInDoubleQuotes]) }
    return SQLExpressionFragment.isSingleExpression(text, readings: printed)
        && SQLExpressionFragment.isSingleExpression(MySQLLiteralSpelling.quoteDoubling.respelled(text), readings: respelled)
}

/// MySQL's marker for an expression default, in `EXTRA` of both catalog reads.
nonisolated internal func mysqlIsExpressionDefault(extra: String?) -> Bool {
    extra?.uppercased().contains("DEFAULT_GENERATED") == true
}

/// Whether a MySQL expression default can only be recreated from `SHOW CREATE TABLE`.
///
/// The catalog keeps an expression default escaped, which `mysqlUnescapedCatalogExpression` undoes
/// exactly, and any non-ASCII text in it encoded twice, which nothing can undo: measured on 8.4.11,
/// `concat('日','x')` comes back with `日` as `æ\u{97}¥`. `SHOW CREATE TABLE` prints it exactly, so an
/// expression holding non-ASCII text is read from there and every other one from the catalog.
nonisolated internal func mysqlExpressionDefaultNeedsCreateTable(
    _ value: String?,
    extra: String?,
    dataType: String
) -> Bool {
    guard mysqlIsExpressionDefault(extra: extra), let value else { return false }
    return !value.unicodeScalars.allSatisfy(\.isASCII)
}

/// Whether a default a MariaDB reports bare may be an expression rather than the string it reads
/// as. Before 10.2.7 its catalog quotes nothing, so `uuid()` and `'uuid()'` both come back `uuid()`.
/// A default with no parenthesis in it cannot be an expression there, and `CURRENT_TIMESTAMP` on a
/// temporal column reads right either way.
nonisolated internal func mariaDBBareDefaultMayBeExpression(_ value: String?, dataType: String) -> Bool {
    guard let value, value.contains("(") else { return false }
    return !(mysqlTemporalType(dataType) && mysqlCurrentTimestampExpression(value, dataType: dataType) != nil)
}

/// An expression default as `SHOW CREATE TABLE` prints it, from the catalog's escaped copy, for a
/// read that has no `SHOW CREATE TABLE` to take it from.
///
/// MySQL stores an expression default with every quote and backslash escaped by a backslash.
/// Measured on 8.4.11, `DEFAULT (concat('a','b'))` comes back as `concat(_utf8mb4\'a\',_utf8mb4\'b\')`,
/// which no statement accepts, so every later edit of the column failed. Undoing it is a pairwise
/// scan in which a backslash takes the next character literally. The escaped form never holds a
/// bare quote, so meeting one means the text was never escaped, and it is returned as it came.
///
/// Non-ASCII text is returned as it came too. The catalog encodes it twice, so unescaping it would
/// produce a statement the server accepts with different text in it, and a default that changes
/// without a word is worse than an edit the server refuses.
nonisolated internal func mysqlUnescapedCatalogExpression(_ value: String) -> String {
    guard value.unicodeScalars.allSatisfy(\.isASCII) else { return value }
    var result = ""
    var index = value.startIndex
    while index < value.endIndex {
        let character = value[index]
        if character == "'" { return value }
        let next = value.index(after: index)
        guard character == "\\" else {
            result.append(character)
            index = next
            continue
        }
        guard next < value.endIndex else { return value }
        result.append(value[next])
        index = value.index(after: next)
    }
    return result
}

// A number, `BIT` or binary default is the SQL that recreates it only when the whole value is that type's literal.
nonisolated internal func mysqlCatalogReportsLiteralAsSQL(
    _ value: String,
    dataType: String,
    banner: String?,
    flavor: MySQLServerFlavor
) -> Bool {
    let base = dataType.uppercased().split(separator: "(", maxSplits: 1).first.map(String.init)?
        .trimmingCharacters(in: .whitespaces) ?? dataType.uppercased()
    switch base {
    case "TINYINT", "SMALLINT", "MEDIUMINT", "INT", "INTEGER", "BIGINT",
         "DECIMAL", "DEC", "NUMERIC", "FIXED", "FLOAT", "DOUBLE", "REAL", "YEAR", "BOOL", "BOOLEAN":
        return PluginNumericLiteral.isValid(value)
    case "BIT":
        return mysqlIsBitLiteral(value)
    case "BINARY", "VARBINARY":
        if flavor.isMariaDB { return mysqlIsQuotedHexLiteral(value) }
        return MySQLServerVersion.reportsBinaryDefaultAsHex(banner: banner, flavor: flavor) && mysqlIsHexNumber(value)
    default:
        return false
    }
}

nonisolated internal func mysqlIsBitLiteral(_ value: String) -> Bool {
    let scalars = Array(value.unicodeScalars)
    guard scalars.count >= 3, scalars[0] == "b" || scalars[0] == "B", scalars[1] == "'", scalars.last == "'" else {
        return false
    }
    return scalars[2 ..< scalars.count - 1].allSatisfy { $0 == "0" || $0 == "1" }
}

// MySQL reads `0X1F` as a name.
nonisolated internal func mysqlIsHexNumber(_ value: String) -> Bool {
    let scalars = Array(value.unicodeScalars)
    return scalars.count >= 3 && scalars[0] == "0" && scalars[1] == "x" && scalars[2...].allSatisfy(mysqlIsHexDigit)
}

nonisolated internal func mysqlIsHexLiteral(_ value: String) -> Bool {
    mysqlIsQuotedHexLiteral(value) || mysqlIsHexNumber(value)
}

// MariaDB 13.0.2 prints a binary default this way in SHOW FULL COLUMNS and INFORMATION_SCHEMA alike.
nonisolated internal func mysqlIsQuotedHexLiteral(_ value: String) -> Bool {
    let scalars = Array(value.unicodeScalars)
    guard scalars.count >= 3, scalars[0] == "x" || scalars[0] == "X", scalars[1] == "'", scalars.last == "'" else {
        return false
    }
    return scalars[2 ..< scalars.count - 1].allSatisfy(mysqlIsHexDigit)
}

nonisolated private func mysqlIsHexDigit(_ scalar: Unicode.Scalar) -> Bool {
    ("0"..."9").contains(scalar) || ("a"..."f").contains(scalar) || ("A"..."F").contains(scalar)
}
