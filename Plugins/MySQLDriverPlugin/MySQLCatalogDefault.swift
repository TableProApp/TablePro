//
//  MySQLCatalogDefault.swift
//  MySQLDriverPlugin
//
//  A column default as the catalog reports it, turned into the SQL that recreates it.
//

import Foundation
import TableProPluginKit

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

/// The SQL that follows `DEFAULT` for a column, or nil when the column has no default.
///
/// A nullable column the catalog gives SQL NULL has `DEFAULT NULL`. MySQL writes that clause itself
/// for a nullable column declared without one, and MariaDB keeps it through `DROP DEFAULT`. The one
/// state this cannot see is a MySQL nullable column whose default was removed with `ALTER COLUMN …
/// DROP DEFAULT`: the catalog reports it the same way, and on `TEXT` so does `SHOW CREATE TABLE`, yet
/// an `INSERT` that omits it fails with `ERROR 1364`. It reads as `NULL` here and everywhere this
/// value goes, schema compare and exported DDL included. Nothing this app writes creates that state,
/// because a `MODIFY` with no `DEFAULT` clause on a nullable column is `DEFAULT NULL` again.
///
/// A generated or AUTO_INCREMENT column has no default whatever the catalog says. MariaDB reports a
/// generated column's as `NULL`, and the server refuses a `DEFAULT` on either.
nonisolated internal func mysqlColumnDefault(
    _ catalog: MySQLCatalogDefault,
    extra: String?,
    dataType: String,
    isNullable: Bool
) -> String? {
    guard !mysqlColumnIsGenerated(extra: extra), mysqlIdentityKind(extra: extra) == nil else { return nil }
    guard let value = catalog.value else { return isNullable ? "NULL" : nil }
    guard case .bare = catalog else { return value }
    return mysqlBareCatalogDefault(value, extra: extra, dataType: dataType)
}

/// The default a `SHOW FULL COLUMNS` row stands for, from the most exact source read for its column.
///
/// The catalog's quoted form comes first where the server has one, then `SHOW CREATE TABLE`, and the
/// row's own bare value last. The bare value alone takes a MariaDB expression default for a string,
/// and leaves a MySQL expression holding non-ASCII text as the catalog encoded it.
nonisolated internal func mysqlShowColumnsDefault(
    _ shown: String?,
    catalog: MySQLCatalogDefault?,
    createTable: MySQLCreateTableDefaults?,
    column: String,
    extra: String?,
    dataType: String,
    isNullable: Bool
) -> String? {
    mysqlColumnDefault(
        catalog ?? createTable?.catalogDefault(forColumn: column, extra: extra) ?? .bare(shown),
        extra: extra,
        dataType: dataType,
        isNullable: isNullable
    )
}

nonisolated private func mysqlBareCatalogDefault(_ value: String, extra: String?, dataType: String) -> String {
    // MySQL 8.0.13 marks a plain `DEFAULT CURRENT_TIMESTAMP` DEFAULT_GENERATED like any other
    // expression, so this has to be answered before the marker is consulted or the one expression
    // MySQL insists on bare comes back parenthesised.
    if mysqlTemporalType(dataType), mysqlCurrentTimestampExpression(value, dataType: dataType) != nil {
        return value
    }
    if mysqlIsExpressionDefault(extra: extra) {
        let expression = mysqlUnescapedCatalogExpression(value)
        return expression.hasPrefix("(") ? expression : "(\(expression))"
    }
    return mysqlCatalogReportsLiteralAsSQL(dataType: dataType)
        ? value : "'\(mysqlEscapeStringLiteral(value))'"
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

/// Whether this column type's catalog default is already the SQL that recreates it.
///
/// A string default comes back stripped of its quotes and has to be given them again. A number, a
/// `BIT` default (`b'1'`) and a binary default (`0x61`) all come back as the literal they are, and
/// quoting one changes what it means: `0x61` quoted stores the four characters rather than the byte.
nonisolated internal func mysqlCatalogReportsLiteralAsSQL(dataType: String) -> Bool {
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
