//
//  PostgreSQLPluginDriver+Views.swift
//  PostgreSQLDriverPlugin
//

import Foundation
import TableProPluginKit
import TableProPostgreSQLCore

extension PostgreSQLPluginDriver {
    // Rebuilt from the catalog with every name qualified: pg_views lost the options and the check option.
    func fetchViewDefinition(view: String, schema: String?) async throws -> String {
        let resolvedSchema = schema ?? core.currentSchema
        let query = PostgreSQLViewDefinition.catalogQuery(name: view, schema: resolvedSchema)
        let result = try await catalogRead(query)
        guard let row = result.rows.first,
              let catalogRow = PostgreSQLViewDefinition.parse(row: row.map(\.asText))
        else {
            throw LibPQPluginError(message: "Failed to fetch definition for view '\(view)'", sqlState: nil, detail: nil)
        }
        return PostgreSQLViewDefinition.statement(name: view, schema: resolvedSchema, row: catalogRow)
    }

    func fetchViewRowEditing(view: String, schema: String?) async throws -> PluginViewRowEditing? {
        let capabilities = catalogCapabilities
        guard capabilities.serverVersion >= PostgreSQLViewRowEditing.minimumServerVersion else { return nil }
        var chain: [PostgreSQLViewRowEditing.Relation] = []
        var query = PostgreSQLViewRowEditing.relationQuery(name: view, schema: schema ?? core.currentSchema)
        while true {
            let row: [String?]?
            do {
                row = try await catalogRead(query).rows.first?.map(\.asText)
            } catch {
                // Once the relation proved to be a view, a failed read must not let it pass for a table.
                if chain.isEmpty { throw error }
                return .readOnly(.couldNotCheck)
            }
            switch PostgreSQLViewRowEditing.step(&chain, row: row) {
            case .notAView:
                return nil
            case .readOnly(let reason):
                return .readOnly(reason)
            case .readRelation(let oid):
                query = PostgreSQLViewRowEditing.relationQuery(oid: oid)
            case .readColumns(let viewOID, let baseOID, let baseSchema):
                let viewColumnsQuery = PostgreSQLViewRowEditing.viewColumnsQuery(viewOID: viewOID)
                guard let viewColumns = try? await catalogRead(viewColumnsQuery),
                      // Relative, so a default reads as it does in the base table's own tab.
                      let baseColumns = try? await catalogRead(
                          PostgreSQLViewRowEditing.baseColumnsQuery(baseOID: baseOID, capabilities: capabilities),
                          namesRelativeTo: baseSchema
                      )
                else { return .readOnly(.couldNotCheck) }
                return PostgreSQLViewRowEditing.resolve(
                    chain: chain,
                    viewColumns: viewColumns.rows.map { $0.map(\.asText) },
                    baseColumns: baseColumns.rows.map { $0.map(\.asText) }
                )
            }
        }
    }

    func objectCommentStatement(name: String, objectType: String, schema: String?, comment: String?) -> String? {
        PostgreSQLRelationSQL.commentStatement(
            name: name,
            schema: schema ?? core.currentSchema,
            objectType: objectType,
            comment: comment
        )
    }

    func refreshMaterializedViewStatement(name: String, schema: String?, concurrently: Bool) -> String? {
        PostgreSQLRelationSQL.refreshStatement(
            name: name,
            schema: schema ?? core.currentSchema,
            concurrently: concurrently
        )
    }

    func concurrentRefreshAvailability(
        materializedView: String,
        schema: String?
    ) async throws -> PluginConcurrentRefreshAvailability? {
        let query = PostgreSQLRelationSQL.concurrentRefreshQuery(
            name: materializedView,
            schema: schema ?? core.currentSchema
        )
        let result = try await catalogRead(query)
        guard let row = result.rows.first, row.count >= 2 else {
            throw LibPQPluginError(
                message: "Materialized view '\(materializedView)' was not found",
                sqlState: nil,
                detail: nil
            )
        }
        return PostgreSQLRelationSQL.concurrentRefreshAvailability(
            isPopulated: row[0].asText == "1",
            hasUsableUniqueIndex: row[1].asText == "1"
        )
    }
}
