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
        case .mysql, .mariadb, .tidb:
            return mysqlType(type)
        case .sqlite:
            return sqliteType(type)
        case .mssql:
            return mssqlType(type)
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
