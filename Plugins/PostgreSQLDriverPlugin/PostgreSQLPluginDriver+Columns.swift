//
//  PostgreSQLPluginDriver+Columns.swift
//  PostgreSQLDriver
//

import Foundation
import TableProPluginKit

extension PostgreSQLPluginDriver {
    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        let safeSchema = escapeStringLiteral(schema ?? core.currentSchema)
        let safeTable = escapeStringLiteral(table)
        let catalog = try await fetchTypeCatalog()
        let projections = columnProjections()
        let query = PostgreSQLSchemaQueries.columnsQuery(
            schemaLiteral: safeSchema,
            tableLiteral: safeTable,
            identityProjection: projections.identity,
            generatedProjection: projections.generated,
            attributeJoin: projections.attributeJoin
        )
        let result = try await execute(query: query)
        return result.rows.compactMap { row in
            mapPgColumnRow(row, tableNameOffset: 0, catalog: catalog)
        }
    }

    func fetchAllColumns(schema: String?) async throws -> [String: [PluginColumnInfo]] {
        let safeSchema = escapeStringLiteral(schema ?? core.currentSchema)
        let catalog = try await fetchTypeCatalog()
        let projections = columnProjections()
        let query = PostgreSQLSchemaQueries.columnsQuery(
            schemaLiteral: safeSchema,
            tableLiteral: nil,
            identityProjection: projections.identity,
            generatedProjection: projections.generated,
            attributeJoin: projections.attributeJoin
        )
        let result = try await execute(query: query)
        var allColumns: [String: [PluginColumnInfo]] = [:]
        for row in result.rows {
            guard row.count >= 5, let tableName = row[0].asText else { continue }
            if let column = mapPgColumnRow(row, tableNameOffset: 1, catalog: catalog) {
                allColumns[tableName, default: []].append(column)
            }
        }
        return allColumns
    }

    private func columnProjections() -> (identity: String, generated: String, attributeJoin: String) {
        let caps = versionedCapabilities
        let identity = caps.hasIdentityColumns ? "a.attidentity" : "NULL::text"
        let generated = caps.hasGeneratedColumns ? "a.attgenerated" : "NULL::text"
        let attributeJoin = (caps.hasIdentityColumns || caps.hasGeneratedColumns) ? """
            LEFT JOIN pg_catalog.pg_attribute a
                ON a.attrelid = st.relid
                AND a.attname = c.column_name
                AND NOT a.attisdropped
            """ : ""
        return (identity, generated, attributeJoin)
    }

    fileprivate func fetchEnumLabelMap() async throws -> [String: [String]] {
        let result = try await execute(query: PostgreSQLSchemaQueries.enumLabelQuery)
        var map: [String: [String]] = [:]
        for row in result.rows {
            guard let schemaName = row[safe: 0]?.asText,
                  let typeName = row[safe: 1]?.asText,
                  let label = row[safe: 2]?.asText else { continue }
            let key = PostgresColumnTypeResolver.qualifiedName(schema: schemaName, name: typeName)
            map[key, default: []].append(label)
        }
        return map
    }

    fileprivate func fetchArrayTypeMap() async throws -> [String: PostgresArrayTypeInfo] {
        let result = try await execute(query: PostgreSQLSchemaQueries.arrayTypeQuery)
        var map: [String: PostgresArrayTypeInfo] = [:]
        for row in result.rows {
            guard let schemaName = row[safe: 0]?.asText,
                  let arrayTypeName = row[safe: 1]?.asText,
                  let elementTypeName = row[safe: 2]?.asText,
                  let elementKind = row[safe: 3]?.asText?.first else { continue }
            let key = PostgresColumnTypeResolver.qualifiedName(schema: schemaName, name: arrayTypeName)
            map[key] = PostgresArrayTypeInfo(elementTypeName: elementTypeName, elementTypeKind: elementKind)
        }
        return map
    }

    fileprivate func fetchTypeCatalog() async throws -> PostgresTypeCatalog {
        let enumLabels = try await fetchEnumLabelMap()
        let arrayTypes = try await fetchArrayTypeMap()
        return PostgresTypeCatalog(enumLabels: enumLabels, arrayTypes: arrayTypes)
    }

    fileprivate func mapPgColumnRow(
        _ row: [PluginCellValue],
        tableNameOffset: Int,
        catalog: PostgresTypeCatalog
    ) -> PluginColumnInfo? {
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
        let udtSchemaIdx = tableNameOffset + 10

        guard row.count > typeIdx,
              let name = row[nameIdx].asText,
              let rawDataType = row[typeIdx].asText
        else { return nil }

        let udtName = row.count > udtIdx ? row[udtIdx].asText : nil
        let udtSchema = row.count > udtSchemaIdx ? row[udtSchemaIdx].asText : nil
        let resolution = PostgresColumnTypeResolver.resolve(
            rawDataType: rawDataType,
            udtSchema: udtSchema,
            udtName: udtName,
            enumLabelsByQualifiedName: catalog.enumLabels,
            arrayTypesByQualifiedName: catalog.arrayTypes
        )
        let allowedValues = resolution.allowedValues
        let dataType = resolution.dataType

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
            isGenerated: attgenerated == "s",
            allowedValues: allowedValues
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
