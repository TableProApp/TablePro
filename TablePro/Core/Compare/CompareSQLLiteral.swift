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

import Foundation
import TableProPluginKit

internal enum CompareSQLLiteral {
    internal static func literal(
        for value: PluginCellValue,
        databaseType: DatabaseType,
        driver: any PluginDatabaseDriver
    ) -> String {
        guard case .bytes(let data) = value else {
            return driver.sqlLiteral(for: value)
        }
        return binaryLiteral(for: data, databaseType: databaseType)
            ?? driver.sqlLiteral(for: value)
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
        case .mysql, .mariadb, .sqlite, .clickhouse, .duckdb, .libsql, .turso, .cloudflareD1:
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
