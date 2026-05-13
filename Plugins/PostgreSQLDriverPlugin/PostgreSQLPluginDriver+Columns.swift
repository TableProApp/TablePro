//
//  PostgreSQLPluginDriver+Columns.swift
//  PostgreSQLDriver
//

import Foundation
import TableProPluginKit

extension PostgreSQLPluginDriver {
    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        let safeSchema = escapeLiteralForColumns(currentSchema ?? "public")
        let safeTable = escapeLiteralForColumns(table)
        let caps = capabilities
        let identityProjection = caps.hasIdentityColumns ? "a.attidentity" : "NULL::text"
        let generatedProjection = caps.hasGeneratedColumns ? "a.attgenerated" : "NULL::text"
        let attributeJoin = (caps.hasIdentityColumns || caps.hasGeneratedColumns) ? """
            LEFT JOIN pg_catalog.pg_attribute a
                ON a.attrelid = st.relid
                AND a.attname = c.column_name
                AND NOT a.attisdropped
            """ : ""
        let query = """
            SELECT
                c.column_name,
                c.data_type,
                c.is_nullable,
                c.column_default,
                c.collation_name,
                pgd.description,
                c.udt_name,
                CASE WHEN pk.column_name IS NOT NULL THEN 'YES' ELSE 'NO' END AS is_pk,
                \(identityProjection),
                \(generatedProjection)
            FROM information_schema.columns c
            LEFT JOIN pg_catalog.pg_statio_all_tables st
                ON st.schemaname = c.table_schema
                AND st.relname = c.table_name
            LEFT JOIN pg_catalog.pg_description pgd
                ON pgd.objoid = st.relid
                AND pgd.objsubid = c.ordinal_position
            \(attributeJoin)
            LEFT JOIN (
                SELECT DISTINCT kcu.column_name
                FROM information_schema.table_constraints tc
                JOIN information_schema.key_column_usage kcu
                    ON tc.constraint_name = kcu.constraint_name
                    AND tc.table_schema = kcu.table_schema
                WHERE tc.constraint_type = 'PRIMARY KEY'
                    AND tc.table_schema = '\(safeSchema)'
                    AND tc.table_name = '\(safeTable)'
            ) pk ON c.column_name = pk.column_name
            WHERE c.table_schema = '\(safeSchema)' AND c.table_name = '\(safeTable)'
            ORDER BY c.ordinal_position
            """
        let result = try await execute(query: query)
        return result.rows.compactMap { row in
            mapPgColumnRow(row, tableNameOffset: 0)
        }
    }

    func fetchAllColumns(schema: String?) async throws -> [String: [PluginColumnInfo]] {
        let safeSchema = escapeLiteralForColumns(currentSchema ?? "public")
        let caps = capabilities
        let identityProjection = caps.hasIdentityColumns ? "a.attidentity" : "NULL::text"
        let generatedProjection = caps.hasGeneratedColumns ? "a.attgenerated" : "NULL::text"
        let attributeJoin = (caps.hasIdentityColumns || caps.hasGeneratedColumns) ? """
            LEFT JOIN pg_catalog.pg_attribute a
                ON a.attrelid = st.relid
                AND a.attname = c.column_name
                AND NOT a.attisdropped
            """ : ""
        let query = """
            SELECT
                c.table_name,
                c.column_name,
                c.data_type,
                c.is_nullable,
                c.column_default,
                c.collation_name,
                pgd.description,
                c.udt_name,
                CASE WHEN pk.column_name IS NOT NULL THEN 'YES' ELSE 'NO' END AS is_pk,
                \(identityProjection),
                \(generatedProjection)
            FROM information_schema.columns c
            LEFT JOIN pg_catalog.pg_statio_all_tables st
                ON st.schemaname = c.table_schema
                AND st.relname = c.table_name
            LEFT JOIN pg_catalog.pg_description pgd
                ON pgd.objoid = st.relid
                AND pgd.objsubid = c.ordinal_position
            \(attributeJoin)
            LEFT JOIN (
                SELECT DISTINCT kcu.table_name, kcu.column_name
                FROM information_schema.table_constraints tc
                JOIN information_schema.key_column_usage kcu
                    ON tc.constraint_name = kcu.constraint_name
                    AND tc.table_schema = kcu.table_schema
                WHERE tc.constraint_type = 'PRIMARY KEY'
                    AND tc.table_schema = '\(safeSchema)'
            ) pk ON c.table_name = pk.table_name AND c.column_name = pk.column_name
            WHERE c.table_schema = '\(safeSchema)'
            ORDER BY c.table_name, c.ordinal_position
            """
        let result = try await execute(query: query)
        var allColumns: [String: [PluginColumnInfo]] = [:]
        for row in result.rows {
            guard row.count >= 5, let tableName = row[0].asText else { continue }
            if let column = mapPgColumnRow(row, tableNameOffset: 1) {
                allColumns[tableName, default: []].append(column)
            }
        }
        return allColumns
    }

    fileprivate func escapeLiteralForColumns(_ str: String) -> String {
        str.replacingOccurrences(of: "'", with: "''")
    }

    fileprivate func mapPgColumnRow(_ row: [PluginCellValue], tableNameOffset: Int) -> PluginColumnInfo? {
        let nameIdx = tableNameOffset
        let typeIdx = tableNameOffset + 1
        let nullableIdx = tableNameOffset + 2
        let defaultIdx = tableNameOffset + 3
        let collationIdx = tableNameOffset + 4
        let commentIdx = tableNameOffset + 5
        let udtIdx = tableNameOffset + 6
        let pkIdx = tableNameOffset + 7
        let identityIdx = tableNameOffset + 8
        let generatedIdx = tableNameOffset + 9

        guard row.count > typeIdx,
              let name = row[nameIdx].asText,
              let rawDataType = row[typeIdx].asText
        else { return nil }

        let udtName = row.count > udtIdx ? row[udtIdx].asText : nil
        let dataType: String
        if rawDataType.uppercased() == "USER-DEFINED", let udt = udtName {
            dataType = "ENUM(\(udt))"
        } else {
            dataType = rawDataType.uppercased()
        }

        let isNullable = row.count > nullableIdx && row[nullableIdx].asText == "YES"
        let defaultValue = row.count > defaultIdx ? row[defaultIdx].asText : nil
        let collation = row.count > collationIdx ? row[collationIdx].asText : nil
        let comment = row.count > commentIdx ? row[commentIdx].asText : nil
        let isPk = row.count > pkIdx && row[pkIdx].asText == "YES"
        let attidentity = row.count > identityIdx ? row[identityIdx].asText : nil
        let attgenerated = row.count > generatedIdx ? row[generatedIdx].asText : nil

        let charset: String? = {
            guard let coll = collation, coll.contains(".") else { return nil }
            return coll.components(separatedBy: ".").last
        }()

        return PluginColumnInfo(
            name: name,
            dataType: dataType,
            isNullable: isNullable,
            isPrimaryKey: isPk,
            defaultValue: defaultValue,
            charset: charset,
            collation: collation,
            comment: comment?.isEmpty == false ? comment : nil,
            identityKind: pgIdentityKind(attidentity),
            isGenerated: attgenerated == "s"
        )
    }

    fileprivate func pgIdentityKind(_ attidentity: String?) -> IdentityKind? {
        switch attidentity {
        case "a": return .always
        case "d": return .byDefault
        default: return nil
        }
    }
}
