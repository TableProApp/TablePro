//
//  StructureColumnReorderHandler.swift
//  TablePro
//
//  Turns a drag in the Structure tab's column list into the statements that reorder the table.
//

import Foundation
import os
import TableProPluginKit

@MainActor
enum StructureColumnReorderHandler {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "StructureColumnReorderHandler")

    enum ReorderError: LocalizedError {
        case noDriver
        case notSupported
        case invalidIndices
        case sqlGenerationFailed
        case executionFailed(String)

        var errorDescription: String? {
            switch self {
            case .noDriver:
                return String(localized: "No active database connection")
            case .notSupported:
                return String(localized: "Column reorder is not supported for this database type")
            case .invalidIndices:
                return String(localized: "Invalid column indices for reorder operation")
            case .sqlGenerationFailed:
                return String(localized: "Failed to generate SQL for column reorder")
            case .executionFailed(let message):
                return String(format: String(localized: "Column reorder failed: %@"), message)
            }
        }
    }

    /// The order a drag asks for, as column names.
    ///
    /// - Parameters:
    ///   - fromIndex: The source row index in the NSTableView (0-based).
    ///   - toIndex: The drop target row index from NSTableView's `acceptDrop`, which is the row
    ///     ABOVE which the item will be inserted, so it may equal `count`.
    static func desiredOrder(
        fromIndex: Int,
        toIndex: Int,
        columnNames: [String]
    ) throws -> [String] {
        guard fromIndex >= 0, fromIndex < columnNames.count,
              toIndex >= 0, toIndex <= columnNames.count else {
            throw ReorderError.invalidIndices
        }
        var names = columnNames
        let moving = names.remove(at: fromIndex)
        /// Removing the source shifts everything below it up by one, so a drop below the source
        /// lands one position too low unless the insertion point moves with it.
        let insertionIndex = fromIndex < toIndex ? toIndex - 1 : toIndex
        names.insert(moving, at: insertionIndex)
        return names
    }

    /// Asks the driver for the statements that produce `desiredOrder`.
    ///
    /// Nothing is executed here. A plan whose cost is a table rebuild is reviewed and confirmed
    /// before it runs, and only the caller knows which of the two it is looking at.
    static func plan(
        desiredOrder: [String],
        workingColumns: [EditableColumnDefinition],
        tableName: String,
        schema: String?,
        connectionId: UUID
    ) async throws -> PluginColumnReorderPlan {
        guard let driver = DatabaseManager.shared.driver(for: connectionId) else {
            throw ReorderError.noDriver
        }
        guard let adapter = driver as? PluginDriverAdapter else {
            throw ReorderError.notSupported
        }

        let plan = try await adapter.generateColumnReorderPlan(
            table: tableName,
            schema: schema,
            columns: workingColumns.map { $0.toPlugin() },
            desiredOrder: desiredOrder
        )
        guard let plan, !plan.statements.isEmpty else {
            throw ReorderError.sqlGenerationFailed
        }
        return plan
    }

    /// Runs a plan the caller has already authorized with the user where its cost demanded it.
    ///
    /// Every statement goes through the execution gate on its own, so Safe Mode and a connection's
    /// read-only policy stop a rebuild at its first statement rather than part way through. A
    /// rebuild holds a transaction open across several of them, so a failure part way runs the
    /// plan's own rollback before reporting: leaving the transaction open would strand the session
    /// on every later statement it ran.
    static func execute(
        _ plan: PluginColumnReorderPlan,
        connectionId: UUID
    ) async throws {
        guard let driver = DatabaseManager.shared.driver(for: connectionId) else {
            throw ReorderError.noDriver
        }
        guard let adapter = driver as? PluginDriverAdapter else {
            throw ReorderError.notSupported
        }

        for (index, sql) in plan.statements.enumerated() {
            let decision = await ExecutionGateProvider.shared.authorize(
                OperationRequest(
                    connectionId: connectionId,
                    databaseType: adapter.connection.type,
                    sql: sql,
                    kind: .schemaMutation,
                    caller: .userInterface,
                    capabilities: .interactiveUser,
                    operationDescription: String(localized: "Reorder Columns")
                )
            )
            guard case .authorized = decision else {
                await rollback(plan, startedStatements: index, driver: driver)
                throw DatabaseError.queryFailed(decision.deniedReason ?? String(localized: "Operation not permitted"))
            }

            logger.info("Reordering columns: \(sql)")

            do {
                _ = try await driver.execute(query: sql)
            } catch {
                logger.error("Column reorder failed: \(error.localizedDescription, privacy: .public)")
                await rollback(plan, startedStatements: index, driver: driver)
                throw ReorderError.executionFailed(error.localizedDescription)
            }
        }
    }

    /// Best effort, and deliberately ungated: it undoes a write the gate already allowed, and a
    /// rollback that a policy could refuse would leave the transaction open instead.
    private static func rollback(
        _ plan: PluginColumnReorderPlan,
        startedStatements: Int,
        driver: any DatabaseDriver
    ) async {
        guard startedStatements > 0, !plan.rollbackStatements.isEmpty else { return }
        for sql in plan.rollbackStatements {
            do {
                _ = try await driver.execute(query: sql)
            } catch {
                logger.error("Column reorder rollback failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
