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
        let result = try await executeQualifiedRead(query)
        guard let row = result.rows.first,
              let catalogRow = PostgreSQLViewDefinition.parse(row: row.map(\.asText))
        else {
            throw LibPQPluginError(message: "Failed to fetch definition for view '\(view)'", sqlState: nil, detail: nil)
        }
        return PostgreSQLViewDefinition.statement(name: view, schema: resolvedSchema, row: catalogRow)
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
        let result = try await execute(query: query)
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

    /// Reads with `search_path` emptied so every name the server deparses comes back qualified.
    ///
    /// A pooled connection is never inside a transaction, and there the prefix and the read form
    /// one implicit transaction that restores the path as it ends. PGlite has no pool, so its reads
    /// share the connection a query tab may have left inside `BEGIN`; the prefix would then outlive
    /// the read and every later unqualified name in that tab would fail. A savepoint scopes it there.
    private func executeQualifiedRead(_ query: String) async throws -> PluginQueryResult {
        let statement = PostgreSQLViewDefinition.qualifiedReadPrefix + query
        guard core.isInsideTransactionBlock else {
            return try await execute(query: statement)
        }
        let savepoint = "tablepro_qualified_read"
        _ = try await execute(query: "SAVEPOINT \(savepoint)")
        /// The rollback is best effort on both paths. It undoes a `SET LOCAL` in a transaction that
        /// is about to end anyway, so a connection lost between the read and the rollback has taken
        /// the whole transaction with it, and reporting that instead of the definition just read
        /// would lose the answer to a failure that no longer matters.
        let release = "ROLLBACK TO SAVEPOINT \(savepoint); RELEASE SAVEPOINT \(savepoint)"
        do {
            let result = try await execute(query: statement)
            _ = try? await execute(query: release)
            return result
        } catch {
            _ = try? await execute(query: release)
            throw error
        }
    }
}
