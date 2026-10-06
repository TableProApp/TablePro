//
//  ImportTypeMapper.swift
//  TablePro
//

import Foundation
import TableProPluginKit

enum ImportTypeMapper {
    static func sqlType(
        for type: PluginImportFieldType,
        databaseType: DatabaseType,
        serverVersion: String? = nil
    ) -> String {
        switch databaseType {
        case .postgresql, .redshift, .cockroachdb:
            return postgresType(
                type,
                jsonColumnType: PostgreSQLServerVersion.jsonColumnType(
                    for: databaseType, serverVersion: serverVersion
                )
            )
        case .mysql, .mariadb, .tidb, .oceanbase:
            return mysqlType(type)
        case .sqlite:
            return sqliteType(type)
        case .mssql:
            return mssqlType(type)
        case .oracle:
            return oracleType(type, majorRelease: oracleMajorRelease(in: serverVersion))
        default:
            return genericType(type)
        }
    }

    private static func postgresType(_ type: PluginImportFieldType, jsonColumnType: PostgreSQLJSONColumnType) -> String {
        switch type {
        case .integer: return "BIGINT"
        case .real: return "DOUBLE PRECISION"
        case .boolean: return "BOOLEAN"
        case .json: return jsonColumnType.rawValue
        case .text: return "TEXT"
        @unknown default: return "TEXT"
        }
    }

    private static func mysqlType(_ type: PluginImportFieldType) -> String {
        switch type {
        case .integer: return "BIGINT"
        case .real: return "DOUBLE"
        case .boolean: return "TINYINT(1)"
        case .json: return "JSON"
        case .text: return "TEXT"
        @unknown default: return "TEXT"
        }
    }

    private static func sqliteType(_ type: PluginImportFieldType) -> String {
        switch type {
        case .integer: return "INTEGER"
        case .real: return "REAL"
        case .boolean: return "INTEGER"
        case .json, .text: return "TEXT"
        @unknown default: return "TEXT"
        }
    }

    private static func mssqlType(_ type: PluginImportFieldType) -> String {
        switch type {
        case .integer: return "BIGINT"
        case .real: return "FLOAT"
        case .boolean: return "BIT"
        case .json, .text: return "NVARCHAR(MAX)"
        @unknown default: return "NVARCHAR(MAX)"
        }
    }

    /// Oracle has no `TEXT` (ORA-00902), and `BOOLEAN` only from 23ai. Text gets the widest `VARCHAR2` rather than a
    /// `CLOB`, which Oracle cannot compare or sort by, and a boolean before 23ai keeps the file's own words, which a
    /// `NUMBER(1)` refuses (ORA-01722). JSON lands in a `CLOB`, the type every release holds it in.
    private static func oracleType(_ type: PluginImportFieldType, majorRelease: Int?) -> String {
        switch type {
        case .integer: return "NUMBER(19)"
        case .real: return "BINARY_DOUBLE"
        case .boolean: return (majorRelease ?? 0) >= 23 ? "BOOLEAN" : "VARCHAR2(5 CHAR)"
        case .json: return "CLOB"
        case .text: return "VARCHAR2(4000 CHAR)"
        @unknown default: return "VARCHAR2(4000 CHAR)"
        }
    }

    /// The release in an Oracle banner, `Oracle Database 19c Enterprise Edition Release 19.0.0.0.0 - Production`.
    static func oracleMajorRelease(in banner: String?) -> Int? {
        guard let banner, let range = banner.range(of: #"\bRelease\s+(\d+)"#, options: .regularExpression) else {
            return nil
        }
        return Int(banner[range].drop { !$0.isNumber })
    }

    private static func genericType(_ type: PluginImportFieldType) -> String {
        switch type {
        case .integer: return "INTEGER"
        case .real: return "DOUBLE PRECISION"
        case .boolean: return "BOOLEAN"
        case .json, .text: return "TEXT"
        @unknown default: return "TEXT"
        }
    }
}
