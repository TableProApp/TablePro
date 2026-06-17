//
//  TriggerEditing.swift
//  TablePro
//
//  Orchestrates create / edit / drop of triggers through the execution gate
//  with per-engine transaction wrapping or rollback-buffer semantics.
//

import Foundation
import os

enum TriggerEditingError: LocalizedError {
    case notConnected
    case denied(String)
    case dropUnavailable

    var errorDescription: String? {
        switch self {
        case .notConnected: String(localized: "Not connected to database")
        case let .denied(reason): reason
        case .dropUnavailable: String(localized: "This database cannot drop triggers")
        }
    }
}

@MainActor
enum TriggerEditing {
    private static let logger = Logger(subsystem: "com.TablePro", category: "TriggerEditing")

    static func apply(
        connection: DatabaseConnection,
        tableName: String,
        sql: String,
        isEdit: Bool,
        originalName: String?,
        originalDefinition: String?
    ) async throws {
        guard let driver = DatabaseManager.shared.driver(for: connection.id) else {
            throw TriggerEditingError.notConnected
        }

        let decision = await ExecutionGateProvider.shared.authorize(
            OperationRequest(
                connectionId: connection.id,
                databaseType: connection.type,
                sql: sql,
                kind: .schemaMutation,
                caller: .userInterface,
                capabilities: .interactiveUser,
                operationDescription: isEdit
                    ? String(localized: "Edit Trigger")
                    : String(localized: "Create Trigger")
            )
        )
        guard case .authorized = decision else {
            throw TriggerEditingError.denied(decision.deniedReason ?? String(localized: "Operation not permitted"))
        }

        let dropSQL: String? = (isEdit && !driver.triggerEditUsesReplace)
            ? originalName.flatMap { driver.generateDropTriggerSQL(name: $0, table: tableName) }
            : nil

        if driver.supportsTransactionalDDL {
            try await runInTransaction(driver: driver, dropSQL: dropSQL, sql: sql)
        } else if let dropSQL {
            try await runDropThenCreate(driver: driver, dropSQL: dropSQL, sql: sql, rollback: originalDefinition)
        } else {
            _ = try await driver.execute(query: sql)
        }

        recordHistory(sql, connection: connection)
        AppCommands.shared.refreshData.send(connection.id)
    }

    static func drop(connection: DatabaseConnection, tableName: String, name: String) async throws {
        guard let driver = DatabaseManager.shared.driver(for: connection.id) else {
            throw TriggerEditingError.notConnected
        }
        guard let dropSQL = driver.generateDropTriggerSQL(name: name, table: tableName) else {
            throw TriggerEditingError.dropUnavailable
        }

        let decision = await ExecutionGateProvider.shared.authorize(
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

        _ = try await driver.execute(query: dropSQL)
        recordHistory(dropSQL, connection: connection)
        AppCommands.shared.refreshData.send(connection.id)
    }

    private static func runInTransaction(driver: DatabaseDriver, dropSQL: String?, sql: String) async throws {
        try await driver.beginTransaction()
        do {
            if let dropSQL { _ = try await driver.execute(query: dropSQL) }
            _ = try await driver.execute(query: sql)
            try await driver.commitTransaction()
        } catch {
            try? await driver.rollbackTransaction()
            throw error
        }
    }

    private static func runDropThenCreate(driver: DatabaseDriver, dropSQL: String, sql: String, rollback: String?) async throws {
        _ = try await driver.execute(query: dropSQL)
        do {
            _ = try await driver.execute(query: sql)
        } catch {
            if let rollback {
                _ = try? await driver.execute(query: rollback)
            }
            throw error
        }
    }

    private static func recordHistory(_ sql: String, connection: DatabaseConnection) {
        QueryHistoryManager.shared.recordQuery(
            query: sql,
            connectionId: connection.id,
            databaseName: DatabaseManager.shared.activeDatabaseName(for: connection),
            executionTime: 0,
            rowCount: 0,
            wasSuccessful: true
        )
    }
}
