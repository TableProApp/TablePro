//
//  CompareSQLLiteral.swift
//  TablePro
//
//  How a compared value is written back as a literal.
//
//  The PluginKit default renders binary as `X'89504E47'`, which is a bit-string
//  literal. MySQL, MariaDB, SQLite and ClickHouse accept it; PostgreSQL rejects
//  it with "column is of type bytea but expression is of type bit", SQL Server
//  wants `0x...` and Oracle wants `HEXTORAW`. No shipped driver overrides
//  `sqlLiteral(for:)`, so the spelling is decided here, per engine, rather than
//  by adding a requirement every plugin would have to be re-released to answer.
//
//  Text is typed by the column it lands in. The PluginKit default passes any
//  numeric-looking string through bare, which wrote a VARCHAR `'007'` as `007`
//  and widened a key predicate to every row MySQL coerces to 7.
//

import Foundation
import TableProPluginKit
import TableProSQLQuoting

internal enum CompareSQLLiteral {
    internal static func literal(
        for value: PluginCellValue,
        columnType: ColumnType?,
        databaseType: DatabaseType,
        driver: any PluginDatabaseDriver,
        keptInScript: Bool = true
    ) -> String {
        switch value {
        case .null:
            return "NULL"
        case .bytes(let data):
            return binaryLiteral(for: data, databaseType: databaseType) ?? driver.sqlLiteral(for: value)
        case .text(let text):
            return textLiteral(
                text, columnType: columnType, databaseType: databaseType, driver: driver, keptInScript: keptInScript
            )
        }
    }

    internal static func textLiteral(
        _ text: String,
        columnType: ColumnType?,
        databaseType: DatabaseType,
        driver: any PluginDatabaseDriver,
        keptInScript: Bool = true
    ) -> String {
        if let columnType, ColumnTypeSQLQuoting.isNumericLiteral(text, for: columnType) {
            return text
        }
        // ClickHouse and MySQL read a backslash as one, so a value ending in `\'` left single closed the literal early
        // (#3777). The script is also copied and saved with no mode declared, so there MySQL gets its own set; a lookup
        // that only runs takes the session's escapes, so it finds a key holding a backslash.
        let session = driver.sessionLexicalState
        let escapes = keptInScript
            ? SQLLexicalResolver.keptTextStringEscapes(for: databaseType, session: session)
            : SQLLexicalResolver.stringEscapes(for: databaseType, session: session)
        return prefixed(SQLQuoting.stringLiteral(text, escapes: escapes), databaseType: databaseType)
    }

    // `N` in front of `NULL` or a bare number is a syntax error, so the opening quote decides.
    internal static func prefixed(_ literal: String, databaseType: DatabaseType) -> String {
        guard literal.unicodeScalars.first == "'" else { return literal }
        return SQLStringLiteralPrefix.forDatabaseType(databaseType) + literal
    }

    internal static func binaryLiteral(for data: Data, databaseType: DatabaseType) -> String? {
        let hex = data.map { String(format: "%02X", $0) }.joined()
        switch binaryStyle(for: databaseType) {
        case .bitString:
            return "X'\(hex)'"
        case .postgresBytea:
            return "'\\x\(hex.lowercased())'::bytea"
        case .zeroX:
            return "0x\(hex)"
        case .hexToRaw:
            return "HEXTORAW('\(hex)')"
        case .unhexFunction:
            return "unhex('\(hex)')"
        case .unknown:
            return nil
        }
    }

    internal enum BinaryStyle {
        case bitString
        case postgresBytea
        case zeroX
        case hexToRaw
        case unhexFunction
        case unknown
    }

    /// Curated per type, the same shape `CompareSyncEngineFamily` uses. A type this does not
    /// name falls back to the driver's own spelling rather than guessing at one.
    internal static func binaryStyle(for databaseType: DatabaseType) -> BinaryStyle {
        switch databaseType {
        case .mysql, .mariadb, .tidb, .databend, .oceanbase, .starrocks, .sqlite, .clickhouse, .libsql, .turso,
             .cloudflareD1:
            return .bitString
        case .duckdb:
            return .unhexFunction
        case .postgresql, .cockroachdb, .redshift, .pglite, .kingbasees:
            return .postgresBytea
        case .mssql:
            return .zeroX
        case .oracle:
            return .hexToRaw
        default:
            return .unknown
        }
    }
}
