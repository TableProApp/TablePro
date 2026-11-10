//
//  TriggerEditing.swift
//  TablePro
//
//  Orchestrates create / edit / drop of triggers through the execution gate
//  with per-engine transaction wrapping or rollback-buffer semantics.
//

import Combine
import Foundation
import os
import TableProPluginKit
import TableProSQLGrammar

enum TriggerEditingError: LocalizedError {
    case notConnected
    case denied(String)
    case dropUnavailable
    case notCreateTrigger
    case definitionUnavailable
    case originalDropped(reason: String, definition: String)

    var errorDescription: String? {
        switch self {
        case .notConnected: String(localized: "Not connected to database")
        case let .denied(reason): reason
        case .dropUnavailable: String(localized: "This database cannot drop triggers")
        case .notCreateTrigger:
            String(
                localized: """
                    The text has no CREATE TRIGGER statement. Saving it would drop the trigger without \
                    creating it again, so nothing was run.
                    """
            )
        case .definitionUnavailable:
            String(
                localized: """
                    The trigger's full definition could not be read, so it could not be restored if the \
                    edit failed. Nothing was run.
                    """
            )
        case let .originalDropped(reason, _):
            String(
                format: String(
                    localized: """
                        The trigger was dropped, the new definition failed, and the original could not be \
                        created again. The trigger no longer exists. Copy the original definition to \
                        recreate it. Error: %@
                        """
                ),
                reason
            )
        }
    }

    var droppedDefinition: String? {
        if case let .originalDropped(_, definition) = self { return definition }
        return nil
    }
}

enum TriggerStatementShape {
    private static let objectKinds: Set<String> = [
        "TRIGGER", "TABLE", "VIEW", "PROCEDURE", "FUNCTION", "INDEX", "EVENT", "DATABASE", "SCHEMA",
        "SEQUENCE", "TYPE", "ROLE", "USER", "PACKAGE"
    ]
    private static let headerReach = 8

    static func createsTrigger(_ sql: String, databaseType: DatabaseType) -> Bool {
        let code = SQLCodeProjection.code(
            of: sql,
            grammar: databaseType.lexicalGrammar,
            revealingExecutableComments: true
        )
        let words = code
            .split { !($0.isLetter || $0.isNumber || $0 == "_") }
            .map { $0.uppercased() }
            .filter { word in !word.allSatisfy(\.isNumber) }
        for (index, word) in words.enumerated() where word == "CREATE" {
            let header = words[(index + 1)...].prefix(headerReach)
            if header.first(where: { objectKinds.contains($0) }) == "TRIGGER" { return true }
        }
        return false
    }
}

struct TriggerApplyPlan: Equatable, Sendable {
    let strategy: TriggerApplyStrategy
    let dropSQL: String?

    var dropsFirst: Bool {
        switch strategy {
        case .transactional(let dropFirst): dropFirst
        case .dropThenCreate: true
        case .direct: false
        }
    }

    // What the gate previews, in the order they run.
    func gatedStatements(for sql: String) -> [String] {
        guard dropsFirst, let dropSQL else { return [] }
        return [dropSQL, sql]
    }
}

enum TriggerApplyStrategy: Equatable {
    case transactional(dropFirst: Bool)
    case dropThenCreate
    case direct

    static func resolve(isEdit: Bool, usesReplace: Bool, transactionalDDL: Bool) -> TriggerApplyStrategy {
        let dropFirst = isEdit && !usesReplace
        if transactionalDDL {
            return .transactional(dropFirst: dropFirst)
        }
        return dropFirst ? .dropThenCreate : .direct
    }
}

@MainActor
enum TriggerEditing {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "TriggerEditing")

    /// Runs on the schema change route, never on the session driver: the trigger's own BEGIN
    /// would join a transaction a query tab left open, and its COMMIT or ROLLBACK would take
    /// that tab's uncommitted work with it.
    static func apply(
        scope: DatabaseScope,
        connection: DatabaseConnection,
        tableName: String,
        sql: String,
        isEdit: Bool,
        originalName: String?,
        originalDefinition: String?,
        gate: any ExecutionGate = ExecutionGateProvider.shared
    ) async throws {
        let plan = try await DatabaseManager.shared.withMetadataDriver(scope: scope) { driver in
            TriggerApplyPlan(
                strategy: TriggerApplyStrategy.resolve(
                    isEdit: isEdit,
                    usesReplace: driver.triggerEditUsesReplace,
                    transactionalDDL: driver.supportsTransactionalDDL
                ),
                dropSQL: originalName.flatMap { driver.generateDropTriggerSQL(name: $0, table: tableName) }
            )
        }
        let restore = try restoreDefinition(
            for: plan, sql: sql, originalDefinition: originalDefinition, databaseType: connection.type
        )

        let decision = await gate.authorize(
            OperationRequest(
                connectionId: connection.id,
                databaseType: connection.type,
                sql: sql,
                kind: .schemaMutation,
                caller: .userInterface,
                capabilities: .interactiveUser,
                operationDescription: isEdit
                    ? String(localized: "Edit Trigger")
                    : String(localized: "Create Trigger"),
                statements: plan.gatedStatements(for: sql)
            )
        )
        guard case .authorized = decision else {
            throw TriggerEditingError.denied(decision.deniedReason ?? String(localized: "Operation not permitted"))
        }

        let startedAt = Date()
        defer {
            CatalogChangeService.shared.record(
                .changed(CatalogChange(connectionId: connection.id, database: scope.database, kinds: .triggers))
            )
        }
        do {
            try await withSchemaChangeDriver(scope: scope) { driver in
                switch plan.strategy {
                case let .transactional(dropFirst):
                    try await runInTransaction(driver: driver, dropSQL: dropFirst ? plan.dropSQL : nil, sql: sql)
                case .dropThenCreate:
                    guard let dropSQL = plan.dropSQL, let restore else { throw TriggerEditingError.dropUnavailable }
                    try await runDropThenCreate(driver: driver, dropSQL: dropSQL, sql: sql, rollback: restore)
                case .direct:
                    _ = try await driver.execute(query: sql)
                }
            }
        } catch let error as TriggerEditingError {
            if error.droppedDefinition != nil {
                AppCommands.shared.objectChanged.send(
                    DatabaseObjectChange(connectionId: connection.id, scope: scope, name: tableName, kind: .structure)
                )
            }
            throw error
        }

        if plan.dropsFirst, let dropSQL = plan.dropSQL {
            await recordHistory(dropSQL, scope: scope, connection: connection, executionTime: 0)
        }
        await recordHistory(sql, scope: scope, connection: connection, executionTime: Date().timeIntervalSince(startedAt))
        AppCommands.shared.objectChanged.send(
            DatabaseObjectChange(connectionId: connection.id, scope: scope, name: tableName, kind: .structure)
        )
    }

    // Refuses, before the gate and before any statement, an edit that would drop the trigger and leave nothing.
    nonisolated static func restoreDefinition(
        for plan: TriggerApplyPlan,
        sql: String,
        originalDefinition: String?,
        databaseType: DatabaseType
    ) throws -> String? {
        guard plan.dropsFirst else { return nil }
        guard plan.dropSQL != nil else { throw TriggerEditingError.dropUnavailable }
        guard TriggerStatementShape.createsTrigger(sql, databaseType: databaseType) else {
            throw TriggerEditingError.notCreateTrigger
        }
        guard plan.strategy == .dropThenCreate else { return nil }
        guard let originalDefinition,
              TriggerStatementShape.createsTrigger(originalDefinition, databaseType: databaseType)
        else {
            throw TriggerEditingError.definitionUnavailable
        }
        return originalDefinition
    }

    static func drop(
        scope: DatabaseScope,
        connection: DatabaseConnection,
        tableName: String,
        name: String,
        gate: any ExecutionGate = ExecutionGateProvider.shared
    ) async throws {
        /// Built on a driver in the scope that will run it, the way `apply` builds its own inside
        /// the lease. The session driver is wherever the sidebar last went, and an engine that
        /// qualifies its DDL with the connection's current database writes that name into a
        /// statement the pooled connection then runs somewhere else.
        let generated = try await DatabaseManager.shared.withMetadataDriver(scope: scope) { driver in
            driver.generateDropTriggerSQL(name: name, table: tableName)
        }
        guard let dropSQL = generated else {
            throw TriggerEditingError.dropUnavailable
        }

        let decision = await gate.authorize(
            OperationRequest(
                connectionId: connection.id,
                databaseType: connection.type,
                sql: dropSQL,
                kind: .destructiveQuery,
                caller: .userInterface,
                capabilities: .interactiveUser,
                operationDescription: String(localized: "Drop Trigger")
            )
        )
        guard case .authorized = decision else {
            throw TriggerEditingError.denied(decision.deniedReason ?? String(localized: "Operation not permitted"))
        }

        let startedAt = Date()
        try await withSchemaChangeDriver(scope: scope) { driver in
            _ = try await driver.execute(query: dropSQL)
        }
        await recordHistory(dropSQL, scope: scope, connection: connection, executionTime: Date().timeIntervalSince(startedAt))
        AppCommands.shared.objectChanged.send(
            DatabaseObjectChange(connectionId: connection.id, scope: scope, name: tableName, kind: .structure)
        )
        CatalogChangeService.shared.record(
            .changed(CatalogChange(connectionId: connection.id, database: scope.database, kinds: .triggers))
        )
    }

    private static func withSchemaChangeDriver(
        scope: DatabaseScope,
        _ body: @Sendable @escaping (DatabaseDriver) async throws -> Void
    ) async throws {
        try await DatabaseManager.shared.withScopedDriver(
            scope: scope,
            route: DatabaseManager.shared.schemaChangeRoute(for: scope),
            cancellation: .protectedWrite,
            body
        )
    }

    static func runInTransaction(driver: DatabaseDriver, dropSQL: String?, sql: String) async throws {
        try await driver.beginTransaction(mode: .readWrite)
        do {
            if let dropSQL { _ = try await driver.execute(query: dropSQL) }
            _ = try await driver.execute(query: sql)
            try await driver.commitTransaction()
        } catch {
            try? await driver.rollbackTransaction()
            throw error
        }
    }

    static func runDropThenCreate(driver: DatabaseDriver, dropSQL: String, sql: String, rollback: String) async throws {
        _ = try await driver.execute(query: dropSQL)
        do {
            _ = try await driver.execute(query: sql)
        } catch {
            do {
                _ = try await driver.execute(query: rollback)
                logger.error("Trigger edit failed; restored original definition: \(error.publicLogShape, privacy: .public)")
            } catch let rollbackError {
                logger.error(
                    """
                    Trigger edit failed and rollback failed, trigger is missing: \
                    edit=\(error.publicLogShape, privacy: .public) \
                    rollback=\(rollbackError.publicLogShape, privacy: .public)
                    """
                )
                throw TriggerEditingError.originalDropped(reason: error.localizedDescription, definition: rollback)
            }
            throw error
        }
    }

    private static func recordHistory(
        _ sql: String,
        scope: DatabaseScope,
        connection: DatabaseConnection,
        executionTime: TimeInterval
    ) async {
        await DatabaseManager.shared.historyRecorder.record(
            QueryHistoryRecordRequest(
                query: sql,
                connectionId: connection.id,
                databaseName: scope.database,
                databaseType: connection.type,
                schemaName: scope.schema,
                source: .structureDDL,
                executionTime: executionTime,
                rowCount: -1,
                wasSuccessful: true
            )
        )
    }
}
