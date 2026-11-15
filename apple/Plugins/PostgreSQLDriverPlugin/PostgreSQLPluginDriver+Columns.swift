//
//  PostgreSQLPluginDriver+Columns.swift
//  PostgreSQLDriver
//

import Foundation
import TableProPluginKit

extension PostgreSQLPluginDriver {
    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        try await exportCatalog.fetchColumns(table: table, schema: schema)
    }

    func fetchAllColumns(schema: String?) async throws -> [String: [PluginColumnInfo]] {
        try await exportCatalog.fetchAllColumns(schema: schema)
    }
}
