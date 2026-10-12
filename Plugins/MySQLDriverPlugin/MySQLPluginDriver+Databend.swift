//
//  MySQLPluginDriver+Databend.swift
//  MySQLDriverPlugin
//

import Foundation
import TableProPluginKit

extension MySQLPluginDriver {
    static let databendCapabilities: PluginCapabilities = [
        .parameterizedQueries,
        .transactions,
        .alterTableDDL,
        .cancelQuery,
    ]

    func databendColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        let query = DatabendCatalog.columnsQuery(database: effectiveSchema(schema), table: table)
        let result = try await execute(query: query)
        return result.rows.compactMap { DatabendCatalog.column(from: $0) }
    }

    func databendAllColumns(schema: String?) async throws -> [String: [PluginColumnInfo]] {
        let result = try await execute(query: DatabendCatalog.allColumnsQuery(database: effectiveSchema(schema)))
        var columns: [String: [PluginColumnInfo]] = [:]
        for row in result.rows {
            guard let table = row[safe: 0]?.asText,
                  let column = DatabendCatalog.column(from: row, offset: 1) else { continue }
            columns[table, default: []].append(column)
        }
        return columns
    }

    func databendCheckConstraints(table: String, schema: String?) async throws -> [PluginCheckConstraintInfo] {
        let query = DatabendCatalog.checkConstraintsQuery(database: effectiveSchema(schema), table: table)
        let result = try await execute(query: query)
        return result.rows.compactMap { row in
            guard let name = row[safe: 0]?.asText,
                  let expression = row[safe: 1]?.asText else { return nil }
            return PluginCheckConstraintInfo(name: name, expression: expression)
        }
    }

    func databendViewDefinition(view: String, schema: String?) async throws -> String {
        let result = try await execute(query: "SHOW CREATE TABLE \(qualifiedName(view, schema: schema))")
        guard let definition = result.rows.first?[safe: 1]?.asText else {
            throw MariaDBPluginError(code: 0, message: "Failed to fetch definition for view '\(view)'", sqlState: nil)
        }
        return definition
    }

    func databendTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        let query = DatabendCatalog.tableMetadataQuery(database: effectiveSchema(schema), table: table)
        let result = try await execute(query: query)
        guard let row = result.rows.first, let metadata = DatabendCatalog.tableMetadata(from: row) else {
            return PluginTableMetadata(tableName: table)
        }
        return metadata
    }

    func databendAllTableMetadata(database: String) async throws -> [String: PluginTableMetadata] {
        let result = try await execute(query: DatabendCatalog.tableMetadataQuery(database: database, table: nil))
        var metadata: [String: PluginTableMetadata] = [:]
        for row in result.rows {
            guard let entry = DatabendCatalog.tableMetadata(from: row) else { continue }
            metadata[entry.tableName] = entry
        }
        return metadata
    }

    func databendCreateDatabase(_ request: PluginCreateDatabaseRequest) async throws {
        _ = try await execute(query: DatabendCatalog.createDatabaseSQL(name: request.name))
    }
}
