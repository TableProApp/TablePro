//
//  DatabaseManager+Schema.swift
//  TablePro
//
//  Created by Ngo Quoc Dat on 16/12/25.
//

import Foundation
import os
import TableProPluginKit

// MARK: - Schema Changes

extension DatabaseManager {
    /// Execute schema changes (ALTER TABLE, CREATE INDEX, etc.) in a transaction
    func executeSchemaChanges(
        tableName: String,
        changes: [SchemaChange],
        databaseType: DatabaseType
    ) async throws {
        guard let sessionId = currentSessionId else {
            throw DatabaseError.notConnected
        }
        try await executeSchemaChanges(
            tableName: tableName,
            changes: changes,
            databaseType: databaseType,
            connectionId: sessionId
        )
    }

    /// Execute schema changes using an explicit connection ID (session-scoped)
    func executeSchemaChanges(
        tableName: String,
        changes: [SchemaChange],
        databaseType: DatabaseType,
        connectionId: UUID
    ) async throws {
        guard let driver = driver(for: connectionId) else {
            throw DatabaseError.notConnected
        }

        try await trackOperation(sessionId: connectionId) {
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

            let useTransaction = driver.supportsTransactions

            if useTransaction {
                try await driver.beginTransaction()
            }

            do {
                for stmt in statements {
                    _ = try await driver.execute(query: stmt.sql)
                }

                if useTransaction {
                    try await driver.commitTransaction()
                }

                // Record each statement in query history
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

                // Post notification to refresh UI
                NotificationCenter.default.post(name: .refreshData, object: nil)
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
        guard databaseType == .postgresql || databaseType == .redshift || databaseType == .duckdb else { return nil }
        guard
            changes.contains(where: {
                if case .modifyPrimaryKey = $0 { return true }
                return false
            })
        else {
            return nil
        }

        // Query the actual constraint name from pg_constraint
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
            if let row = result.rows.first, let name = row[0], !name.isEmpty {
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
