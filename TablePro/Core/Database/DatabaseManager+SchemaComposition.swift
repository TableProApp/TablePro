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

    /// Composes a Structure save for SQL Preview and for Save. The per-operation refusals run first
    /// and cost nothing; the driver's save-level review follows, reading the server where the
    /// engine needs it, and can refuse the save or put statements ahead of it.
    func schemaChangeStatements(
        tableName: String,
        changes: [SchemaChange],
        scope: DatabaseScope
    ) async throws -> SchemaChangeScript {
        try await withSchemaComposer(scope: scope, route: schemaChangeRoute(for: scope)) { driver, pluginDriver in
            let constraintName = await PrimaryKeyConstraintLookup.constraintName(
                tableName: tableName,
                changes: changes,
                driver: driver
            )
            let generator = SchemaStatementGenerator(
                tableName: tableName,
                primaryKeyConstraintName: constraintName,
                pluginDriver: pluginDriver
            )
            let statements = try generator.generate(changes: changes)
            let operations = generator.orderedOperations(for: changes)
            let review = try await driver.reviewSchemaChange(
                table: tableName,
                schema: scope.schema,
                operations: operations
            )
            if let refusal = review.refusal {
                throw SchemaOperationRefusedError(reason: refusal)
            }
            let leading = review.leadingStatements.map { sql in
                SchemaStatement(
                    sql: sql.hasSuffix(";") ? sql : sql + ";",
                    description: "Prepare '\(tableName)'",
                    isDestructive: false
                )
            }
            return SchemaChangeScript(
                tableName: tableName,
                statements: leading + statements,
                operations: operations,
                review: review
            )
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
