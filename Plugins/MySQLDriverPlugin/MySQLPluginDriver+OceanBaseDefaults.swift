//
//  MySQLPluginDriver+OceanBaseDefaults.swift
//  MySQLDriverPlugin
//

import Foundation
import os
import TableProPluginKit

internal extension MySQLPluginDriver {
    func oceanbaseDefaultClausesByTable(
        forRows rows: [[PluginCellValue]],
        tableColumn: Int,
        typeColumn: Int,
        defaultColumn: Int,
        schema: String?
    ) async throws -> [String: [String: String]] {
        guard flavor.isOceanBase else { return [:] }
        let candidates = Set(rows.compactMap { row -> String? in
            guard let table = row[safe: tableColumn]?.asText,
                  let dataType = row[safe: typeColumn]?.asText,
                  OceanBaseColumnDefaults.catalogDefaultNeedsCreateTable(
                      row[safe: defaultColumn]?.asText, dataType: dataType
                  )
            else { return nil }
            return table
        })
        guard !candidates.isEmpty else { return [:] }
        var clausesByTable: [String: [String: String]] = [:]
        for table in try await baseTableNames(among: candidates, schema: schema).sorted() {
            clausesByTable[table] = try await oceanbaseDefaultClauses(table: table, schema: schema)
        }
        return clausesByTable
    }

    func columnDefaultValue(
        catalogDefault: String?,
        extra: String?,
        dataType: String,
        isNullable: Bool,
        column: String,
        createTableClauses: [String: String]?,
        createTableDefaults: MySQLCreateTableDefaults?
    ) -> String? {
        if flavor.isOceanBase, let catalogDefault {
            if let currentTimestamp = OceanBaseColumnDefaults.currentTimestampDefault(catalogDefault, dataType: dataType) {
                return currentTimestamp
            }
            if let createTableClauses,
               OceanBaseColumnDefaults.catalogDefaultNeedsCreateTable(catalogDefault, dataType: dataType) {
                let resolution = OceanBaseColumnDefaults.resolve(
                    clause: createTableClauses[column], catalogDefault: catalogDefault
                )
                if case .value(let value) = resolution {
                    return value
                }
                Self.logger.warning(
                    "OceanBase default of \(column, privacy: .public) is not in SHOW CREATE TABLE as reported"
                )
            }
            if let binaryLiteral = OceanBaseColumnDefaults.binaryLiteralDefault(catalogDefault, dataType: dataType) {
                return binaryLiteral
            }
        }
        return mysqlColumnDefault(
            createTableDefaults?.catalogDefault(forColumn: column, extra: extra)
                ?? (catalogQuotesDefaults ? .quoted(catalogDefault) : .bare(catalogDefault)),
            extra: extra,
            dataType: dataType,
            isNullable: isNullable
        )
    }

    private func baseTableNames(among tables: Set<String>, schema: String?) async throws -> Set<String> {
        let names = tables.sorted().map { "'\(mysqlEscapeStringLiteral($0))'" }.joined(separator: ", ")
        let result = try await execute(query: """
            SELECT TABLE_NAME FROM INFORMATION_SCHEMA.TABLES
            WHERE TABLE_SCHEMA = '\(effectiveSchemaLiteral(schema))'
                AND TABLE_TYPE = 'BASE TABLE'
                AND TABLE_NAME IN (\(names))
            """)
        return Set(result.rows.compactMap { $0[safe: 0]?.asText })
    }

    private func oceanbaseDefaultClauses(table: String, schema: String?) async throws -> [String: String] {
        let result = try await execute(query: "SHOW CREATE TABLE \(qualifiedName(table, schema: schema))")
        guard let createTable = result.rows.first?[safe: 1]?.asText else { return [:] }
        return MySQLCreateTableScanner.columnDefaultClauses(fromCreateTable: createTable) ?? [:]
    }
}
