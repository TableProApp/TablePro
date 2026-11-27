import Foundation
import TableProPluginKit

nonisolated enum ImportTypeMapper {
    static func sqlType(
        for type: PluginImportFieldType,
        databaseTypeId: String,
        serverVersion: String? = nil
    ) -> String {
        switch databaseTypeId {
        case "PostgreSQL", "Redshift", "CockroachDB", "KingbaseES":
            return postgresType(
                type,
                jsonColumnType: postgresJSONColumnType(databaseTypeId: databaseTypeId, serverVersion: serverVersion)
            )
        case "MySQL", "MariaDB", "TiDB", "OceanBase":
            return mysqlType(type)
        case "SQLite":
            return sqliteType(type)
        case "SQL Server":
            return mssqlType(type)
        case "Oracle":
            return oracleType(type, majorRelease: oracleMajorRelease(in: serverVersion))
        default:
            return genericType(type)
        }
    }

    // Only PostgreSQL itself is read from its version: Redshift reports 8.0.2 and CockroachDB 13.0.0, and neither number
    // says what JSON support the engine has.
    static func postgresJSONColumnType(databaseTypeId: String, serverVersion: String?) -> PostgreSQLJSONColumnType {
        guard databaseTypeId == "PostgreSQL", let version = PostgreSQLServerVersion(serverVersion) else {
            return .jsonb
        }
        if version >= .jsonbType { return .jsonb }
        return version >= .jsonType ? .json : .text
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

    // SQLite stores a boolean as 1 or 0. `BOOLEAN` has NUMERIC affinity and tells the import and the grid the column is one.
    private static func sqliteType(_ type: PluginImportFieldType) -> String {
        switch type {
        case .integer: return "INTEGER"
        case .real: return "REAL"
        case .boolean: return "BOOLEAN"
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

    // Oracle has no TEXT (ORA-00902) and BOOLEAN only from 23ai. Text takes the widest VARCHAR2, since a CLOB cannot be
    // compared or sorted; a boolean before 23ai keeps the file's words, which NUMBER(1) refuses (ORA-01722).
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

    // `Oracle Database 19c Enterprise Edition Release 19.0.0.0.0 - Production` is release 19.
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
