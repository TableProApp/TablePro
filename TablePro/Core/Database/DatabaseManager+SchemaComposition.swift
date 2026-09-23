//
//  DatabaseManager+SchemaComposition.swift
//  TablePro
//

import Foundation
import TableProPluginKit
import TableProSQLGrammar

extension DatabaseManager {
    func withSchemaComposer<T: Sendable>(
        scope: DatabaseScope,
        route: ScopedDriverRoute,
        _ body: @Sendable @escaping (DatabaseDriver, any PluginDatabaseDriver) async throws -> T
    ) async throws -> T {
        try await withScopedDriver(scope: scope, route: route, cancellation: .untracked) { driver in
            guard let pluginDriver = (driver as? PluginDriverAdapter)?.schemaPluginDriver else {
                throw DatabaseError.unsupportedOperation
            }
            return try await body(driver, pluginDriver)
        }
    }

    func schemaChangeStatements(
        tableName: String,
        changes: [SchemaChange],
        scope: DatabaseScope
    ) async throws -> [SchemaStatement] {
        try await withSchemaComposer(scope: scope, route: schemaChangeRoute(for: scope)) { driver, pluginDriver in
            let constraintName = await PrimaryKeyConstraintLookup.constraintName(
                tableName: tableName,
                changes: changes,
                driver: driver
            )
            return try SchemaStatementGenerator(
                tableName: tableName,
                primaryKeyConstraintName: constraintName,
                pluginDriver: pluginDriver
            ).generate(changes: changes)
        }
    }

    func createTableStatements(
        plan: CreateTablePlan,
        scope: DatabaseScope
    ) async throws -> CreateTableStatements {
        guard plan.definition != nil else {
            return CreateTableStatements(statements: [], issues: plan.issues, tableName: nil)
        }
        return try await withSchemaComposer(scope: scope, route: schemaChangeRoute(for: scope)) { _, pluginDriver in
            await MainActor.run {
                CreateTableStatementComposer.compose(plan: plan, driver: pluginDriver)
            }
        }
    }

    func createTableStatements(
        definition: PluginCreateTableDefinition,
        scope: DatabaseScope,
        route: ScopedDriverRoute
    ) async throws -> [String] {
        try await withSchemaComposer(scope: scope, route: route) { _, pluginDriver in
            (pluginDriver.generateCreateTableStatements(definition: definition) ?? [])
                .map { StatementBlank.trimming($0) }
                .filter { !$0.isEmpty }
        }
    }
}
