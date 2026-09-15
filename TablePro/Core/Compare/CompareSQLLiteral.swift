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

internal enum CompareSQLLiteral {
    internal static func literal(
        for value: PluginCellValue,
        columnType: ColumnType?,
        databaseType: DatabaseType,
        driver: any PluginDatabaseDriver
    ) -> String {
        switch value {
        case .null:
            return "NULL"
        case .bytes(let data):
            return binaryLiteral(for: data, databaseType: databaseType) ?? driver.sqlLiteral(for: value)
        case .text(let text):
            return textLiteral(text, columnType: columnType, databaseType: databaseType, driver: driver)
        }
    }

    internal static func textLiteral(
        _ text: String,
        columnType: ColumnType?,
        databaseType: DatabaseType,
        driver: any PluginDatabaseDriver
    ) -> String {
        if let columnType, ColumnTypeSQLQuoting.isNumericLiteral(text, for: columnType) {
            return text
        }
        let rendered = driver.sqlLiteral(for: .text(text))
        /// A driver that passed the value through unquoted answered for a number, so the value holds
        /// no quote to escape. Escaping anyway is what keeps that true if a driver ever renders a
        /// quoted literal some other way.
        let quoted = rendered.hasPrefix("'")
            ? rendered
            : "'\(text.replacingOccurrences(of: "'", with: "''"))'"
        return prefixed(quoted, databaseType: databaseType)
    }

    /// The prefix belongs to a quoted literal and to nothing else. `sqlLiteral(for:)` answers
    /// `NULL` for a null and passes a number through unquoted, and `N` in front of either is a
    /// syntax error, so the opening quote is what decides.
    internal static func prefixed(_ literal: String, databaseType: DatabaseType) -> String {
        guard literal.hasPrefix("'") else { return literal }
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
        case .unknown:
            return nil
        }
    }

    internal enum BinaryStyle {
        case bitString
        case postgresBytea
        case zeroX
        case hexToRaw
        case unknown
    }

    /// Curated per type, the same shape `CompareSyncEngineFamily` uses. A type this does not
    /// name falls back to the driver's own spelling rather than guessing at one.
    internal static func binaryStyle(for databaseType: DatabaseType) -> BinaryStyle {
        switch databaseType {
        case .mysql, .mariadb, .tidb, .databend, .oceanbase, .sqlite, .clickhouse, .duckdb, .libsql,
             .turso, .cloudflareD1:
            return .bitString
        case .postgresql, .cockroachdb, .redshift, .pglite:
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
