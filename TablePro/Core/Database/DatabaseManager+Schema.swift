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
    /// Execute schema changes (ALTER TABLE, CREATE INDEX, etc.) in a transaction.
    /// The connection, database, and schema all come from the caller's own tab, never
    /// from ambient session state that another window or tab can move.
    func executeSchemaChanges(
        tableName: String,
        changes: [SchemaChange],
        databaseType: DatabaseType,
        databaseName: String,
        schemaName: String?,
        connectionId: UUID
    ) async throws {
        guard let driver = driver(for: connectionId) else {
            throw DatabaseError.notConnected
        }

        try await trackOperation(sessionId: connectionId) {
            try await pinDatabaseBeforeSchemaChange(
                databaseName: databaseName,
                schemaName: schemaName,
                databaseType: databaseType,
                connectionId: connectionId
            )

            // For PostgreSQL PK modification, query the actual constraint name
            let pkConstraintName = await fetchPrimaryKeyConstraintName(
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
            let statements = try generator.generate(changes: changes)

            let combinedSQL = statements.map(\.sql).joined(separator: "\n")
            let schemaKind: OperationKind =
                QueryClassifier.classifyTier(combinedSQL, databaseType: databaseType) == .destructive
                ? .destructiveQuery : .schemaMutation
            let authorization = await ExecutionGateProvider.shared.authorize(
                OperationRequest(
                    connectionId: connectionId,
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

            let useTransaction = driver.supportsTransactions

            if useTransaction {
                try await driver.beginTransaction(mode: schemaKind.declaresWrite ? .readWrite : .serverDefault)
            }

            do {
                for stmt in statements {
                    _ = try await driver.execute(query: stmt.sql)
                }

                if useTransaction {
                    try await driver.commitTransaction()
                }

                let connId = connectionId
                let dbName = self.activeSessions[connectionId]?.activeDatabase ?? ""
                for stmt in statements {
                    QueryHistoryManager.shared.recordQuery(
                        query: stmt.sql.hasSuffix(";") ? stmt.sql : stmt.sql + ";",
                        connectionId: connId,
                        databaseName: dbName,
                        executionTime: 0,
                        rowCount: 0,
                        wasSuccessful: true
                    )
                }

                await MainActor.run {
                    AppCommands.shared.refreshData.send(connectionId)
                }
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
    }

    /// Point the shared session driver at the database and schema the edited table
    /// belongs to. Sibling tabs on the same connection move that driver, so a save must
    /// re-pin before it writes. A failed pin aborts the save: a misdirected DDL is
    /// silent and often irreversible, unlike a misdirected read.
    ///
    /// Switching database on a schema-grouped engine drops the driver back to the engine's
    /// default schema, and those drivers qualify their DDL with whatever schema they are
    /// currently on, so the schema has to be restored before any statement is generated.
    private func pinDatabaseBeforeSchemaChange(
        databaseName: String,
        schemaName: String?,
        databaseType: DatabaseType,
        connectionId: UUID
    ) async throws {
        guard !databaseName.isEmpty,
              !pluginManager.requiresReconnectForDatabaseSwitch(for: databaseType),
              databaseName != activeSessions[connectionId]?.activeDatabase
        else {
            return
        }

        let targetSchema = resolvedSchemaName(schemaName, for: connectionId)

        do {
            try await switchDatabase(to: databaseName, for: connectionId, persist: false)
            try await restoreSchemaAfterDatabasePin(targetSchema, for: connectionId)
        } catch {
            throw DatabaseError.queryFailed(
                String(
                    format: String(localized: "Could not switch to database %@ before applying schema changes: %@"),
                    databaseName,
                    error.localizedDescription
                )
            )
        }
    }

    private func restoreSchemaAfterDatabasePin(_ targetSchema: String?, for connectionId: UUID) async throws {
        guard let targetSchema, !targetSchema.isEmpty,
              let schemaDriver = driver(for: connectionId) as? SchemaSwitchable,
              schemaDriver.currentSchema != targetSchema
        else {
            return
        }

        try await switchSchema(to: targetSchema, for: connectionId)
    }

    /// Query the actual primary key constraint name for PostgreSQL.
    /// Returns nil if the database is not PostgreSQL, no PK modification is pending,
    /// or the query fails (caller falls back to `{table}_pkey` convention).
    private func fetchPrimaryKeyConstraintName(
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
