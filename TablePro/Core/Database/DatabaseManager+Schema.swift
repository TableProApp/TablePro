//
//  DatabaseManager+Schema.swift
//  TablePro
//
//  Created by Ngo Quoc Dat on 16/12/25.
//

import Combine
import Foundation
import os
import TableProPluginKit

// MARK: - Schema Changes

extension DatabaseManager {
    /// Execute schema changes (ALTER TABLE, CREATE INDEX, etc.) in a transaction of their own,
    /// on the schema change route rather than the session driver a query tab may have left
    /// mid-transaction. The connection, database and schema all come from the editing tab's
    /// own scope, never from ambient session state that another window or tab can move.
    ///
    /// Authorization sits between two scoped blocks rather than inside one: it awaits a
    /// confirmation sheet and Touch ID, and holding the connection's driver gate across a
    /// human prompt would freeze every other tab on that connection.
    func executeSchemaChanges(
        tableName: String,
        changes: [SchemaChange],
        databaseType: DatabaseType,
        scope: DatabaseScope
    ) async throws {
        let route = schemaChangeRoute(for: scope)

        let statements = try await withScopedDriver(
            scope: scope, route: route, cancellation: .untracked
        ) { driver in
            let pkConstraintName = await Self.fetchPrimaryKeyConstraintName(
                tableName: tableName,
                databaseType: databaseType,
                changes: changes,
                driver: driver
            )
            guard let resolvedPluginDriver = (driver as? PluginDriverAdapter)?.schemaPluginDriver else {
                throw DatabaseError.unsupportedOperation
            }
            let generator = SchemaStatementGenerator(
                tableName: tableName,
                primaryKeyConstraintName: pkConstraintName,
                pluginDriver: resolvedPluginDriver
            )
            return try generator.generate(changes: changes)
        }

        let combinedSQL = statements.map(\.sql).joined(separator: "\n")
        let schemaKind: OperationKind =
            QueryClassifier.classifyTier(combinedSQL, databaseType: databaseType) == .destructive
            ? .destructiveQuery : .schemaMutation
        let authorization = await ExecutionGateProvider.shared.authorize(
            OperationRequest(
                connectionId: scope.connectionId,
                databaseType: databaseType,
                sql: combinedSQL,
                kind: schemaKind,
                caller: .userInterface,
                capabilities: .interactiveUser,
                operationDescription: String(localized: "Apply Schema Changes")
            )
        )
        guard case .authorized = authorization else {
            throw DatabaseError.queryFailed(
                authorization.deniedReason ?? String(localized: "Schema change was not authorized")
            )
        }

        let executionTimes: [TimeInterval] = try await withScopedDriver(
            scope: scope,
            route: route,
            cancellation: .protectedWrite
        ) { driver in
            let useTransaction = driver.supportsTransactions
            if useTransaction {
                try await driver.beginTransaction(mode: schemaKind.declaresWrite ? .readWrite : .serverDefault)
            }
            do {
                var measured: [TimeInterval] = []
                for stmt in statements {
                    let startedAt = Date()
                    _ = try await driver.execute(query: stmt.sql)
                    measured.append(Date().timeIntervalSince(startedAt))
                }
                if useTransaction {
                    try await driver.commitTransaction()
                }
                return measured
            } catch {
                if useTransaction {
                    do {
                        try await driver.rollbackTransaction()
                    } catch {
                        Self.logger.error("Rollback failed after schema change error: \(error.localizedDescription)")
                    }
                }
                throw DatabaseError.queryFailed("Schema change failed: \(error.localizedDescription)")
            }
        }

        let databaseTypeForHistory = databaseType
        for (index, stmt) in statements.enumerated() {
            await historyRecorder.record(
                QueryHistoryRecordRequest(
                    query: stmt.sql.hasSuffix(";") ? stmt.sql : stmt.sql + ";",
                    connectionId: scope.connectionId,
                    databaseName: scope.database,
                    databaseType: databaseTypeForHistory,
                    schemaName: scope.schema,
                    source: .structureDDL,
                    executionTime: executionTimes.indices.contains(index) ? executionTimes[index] : 0,
                    rowCount: -1,
                    wasSuccessful: true
                )
            )
        }

        AppCommands.shared.refreshData.send(DataRefreshRequest(connectionId: scope.connectionId, scope: scope))
    }

    /// Query the actual primary key constraint name for PostgreSQL.
    /// Returns nil if the database is not PostgreSQL, no PK modification is pending,
    /// or the query fails (caller falls back to `{table}_pkey` convention).
    private static func fetchPrimaryKeyConstraintName(
        tableName: String,
        databaseType: DatabaseType,
        changes: [SchemaChange],
        driver: DatabaseDriver
    ) async -> String? {
        // Only needed for PostgreSQL PK modifications
        guard databaseType == .postgresql || databaseType == .redshift
            || databaseType == .cockroachdb || databaseType == .duckdb else { return nil }
        guard
            changes.contains(where: {
                if case .modifyPrimaryKey = $0 { return true }
                return false
            })
        else {
            return nil
        }

        let escapedTable = tableName.replacingOccurrences(of: "'", with: "''")
        let schema: String
        if let schemaDriver = driver as? SchemaSwitchable,
           let escaped = schemaDriver.escapedSchema {
            schema = escaped
        } else {
            schema = "public"
        }
        let query = """
            SELECT con.conname
            FROM pg_constraint con
            JOIN pg_class rel ON rel.oid = con.conrelid
            JOIN pg_namespace nsp ON nsp.oid = rel.relnamespace
            WHERE rel.relname = '\(escapedTable)'
              AND nsp.nspname = '\(schema)'
              AND con.contype = 'p'
            LIMIT 1
            """

        do {
            let result = try await driver.execute(query: query)
            if let row = result.rows.first, let name = row[0].asText, !name.isEmpty {
                return name
            }
        } catch {
            // Query failed - fall back to convention in SchemaStatementGenerator
            Self.logger.warning(
                "Failed to query PK constraint name for '\(tableName)': \(error.localizedDescription)"
            )
        }

        return nil
    }
}
