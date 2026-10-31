//
//  PostgreSQLPluginDriver+Views.swift
//  PostgreSQLDriverPlugin
//

import Foundation
import TableProPluginKit

extension PostgreSQLPluginDriver {
    /// `pg_views` and `pg_matviews` return the query alone, so the definition this used to build
    /// from them lost the view's options and check option, and read the body under the connection's
    /// own search path. The statement is now rebuilt from the catalog with every name qualified.
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
        let resolvedSchema = schema ?? core.currentSchema
        let viewResult = try await catalogRead(PostgreSQLViewRowEditing.viewQuery(name: view, schema: resolvedSchema))
        guard let row = viewResult.rows.first, let viewOID = row[safe: 0]?.asText else { return nil }
        let isUpdatable = row[safe: 1]?.asText == "true"
        let origins = PostgreSQLViewRowEditing.targetOrigins(nodeTree: row[safe: 2]?.asText ?? "")
        guard isUpdatable, let baseTableOID = origins.first?.tableOID else {
            return PostgreSQLViewRowEditing.resolve(
                isUpdatable: isUpdatable, origins: origins, viewColumnNames: [:], baseKeyColumnNumbers: []
            )
        }

        let detail = try await catalogRead(
            PostgreSQLViewRowEditing.columnsAndKeyQuery(viewOID: viewOID, baseTableOID: baseTableOID)
        )
        var viewColumnNames: [Int: String] = [:]
        var baseKeyColumnNumbers: [Int] = []
        for detailRow in detail.rows {
            guard let number = detailRow[safe: 1]?.asText.flatMap(Int.init) else { continue }
            switch detailRow[safe: 0]?.asText {
            case "v": viewColumnNames[number] = detailRow[safe: 2]?.asText
            case "k": baseKeyColumnNumbers.append(number)
            default: break
            }
        }
        return PostgreSQLViewRowEditing.resolve(
            isUpdatable: isUpdatable,
            origins: origins,
            viewColumnNames: viewColumnNames,
            baseKeyColumnNumbers: baseKeyColumnNumbers
        )
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
