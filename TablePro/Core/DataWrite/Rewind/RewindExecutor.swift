//
//  RewindExecutor.swift
//  TablePro
//
//  Plans a rewind, then applies it, on the same terms as any other write.
//
//  A rewind is not a privileged operation. It goes through the execution gate, so Safe Mode and a
//  read-only connection govern it exactly as they govern a save; it takes the same scoped driver
//  lease; and it lands in query history. It is also itself recorded, so undoing an undo is an
//  ordinary rewind rather than a special case.
//

import Foundation
import os
import TableProPluginKit

struct RewindApplyResult: Sendable {
    let restoredRows: Int
    let skippedRows: Int
    let statementCount: Int
}

@MainActor
struct RewindExecutor {
    private static let logger = Logger(subsystem: "com.TablePro", category: "RewindExecutor")

    let connection: DatabaseConnection
    let scope: DatabaseScope

    func plan(for record: RewindRecord, factory: RowChangeStatementFactory) async throws -> RewindPlan {
        let planner = RewindPlanner(
            record: record,
            factory: factory,
            queryBuilder: TableQueryBuilder(
                databaseType: connection.type,
                pluginDriver: factory.pluginDriver,
                dialect: PluginManager.shared.sqlDialect(for: connection.type)
            )
        )
        let queries = planner.readQueries()
        let route = DatabaseManager.shared.executionRoute(for: scope)
        let currentRows = try await DatabaseManager.shared.withScopedDriver(
            scope: scope,
            route: route,
            cancellation: .cancellableRead
        ) { driver in
            var rows: [[PluginCellValue]] = []
            for query in queries {
                rows.append(contentsOf: try await driver.execute(query: query).rows)
            }
            return rows
        }
        return try planner.plan(currentRows: currentRows)
    }

    /// A restore is an ordinary write, so it goes into query history like one.
    private func recordHistory(for plan: RewindPlan, results: [DataWriteStepResult]) {
        for (statement, result) in zip(plan.statements, results) {
            let sql = statement.sql.trimmingCharacters(in: .whitespacesAndNewlines)
            let request = QueryHistoryRecordRequest(
                query: sql.hasSuffix(";") ? sql : sql + ";",
                connectionId: connection.id,
                databaseName: scope.database,
                databaseType: connection.type,
                schemaName: scope.schema,
                source: .rowEdit,
                executionTime: result.executionTime,
                rowCount: result.rowsAffected,
                wasSuccessful: true
            )
            Task(priority: .utility) { await QueryHistoryManager.shared.record(request) }
        }
    }

    /// Keeps the restore itself restorable, by storing it as the save it is: the rows it touched,
    /// with the images the other way round. Undoing an undo is then the same operation again
    /// rather than a special case.
    private func captureInverseRecord(for plan: RewindPlan) async {
        guard AppSettingsManager.shared.history.keepRewindHistory else { return }
        let operations = plan.rows.filter { $0.outcome.restores }.map { row -> RowWriteOperation in
            let source = row.operation
            return RowWriteOperation(
                kind: source.kind.inverted,
                target: source.target,
                columns: source.columns,
                primaryKeyColumns: source.primaryKeyColumns,
                preImage: source.postImage,
                postImage: source.preImage,
                writtenColumns: source.writtenColumns,
                refusal: nil
            )
        }
        guard !operations.isEmpty else { return }

        await QueryHistoryManager.shared.recordRewindSnapshot(
            RewindRecord(
                id: UUID(),
                historyId: nil,
                connectionId: connection.id,
                databaseType: connection.type,
                target: plan.record.target,
                capturedAt: Date(),
                generatedColumns: plan.record.generatedColumns,
                operations: operations
            )
        )
    }

    func apply(_ plan: RewindPlan) async throws -> RewindApplyResult {
        let displaySQL = plan.statements
            .map { SQLParameterInliner.inline($0, databaseType: connection.type) }
            .joined(separator: "\n")

        let writePlan = DataWritePlan(
            scope: scope,
            databaseType: connection.type,
            steps: plan.statements.map {
                DataWriteStep(
                    kind: .rowWrite,
                    statement: $0,
                    expectedRowCount: 1,
                    tableName: plan.record.target.table
                )
            }
        )

        let route = DatabaseManager.shared.executionRoute(for: scope)
        let run = try await ExecutionGateProvider.shared.authorizing(
            OperationRequest(
                connectionId: connection.id,
                databaseType: connection.type,
                sql: displaySQL,
                kind: .writeQuery,
                caller: .userInterface,
                capabilities: .interactiveUser,
                operationDescription: String(localized: "Restore Previous Values")
            )
        ) {
            try await DatabaseManager.shared.withScopedDriver(
                scope: scope,
                route: route,
                cancellation: .protectedWrite
            ) { driver in
                try await DataWriteExecutor.run(writePlan, on: driver)
            }
        }

        recordHistory(for: plan, results: run.results)
        await captureInverseRecord(for: plan)

        Self.logger.info(
            "Restored \(plan.restorableCount, privacy: .public) rows in \(run.results.count, privacy: .public) statements"
        )
        return RewindApplyResult(
            restoredRows: plan.restorableCount,
            skippedRows: plan.skippedCount,
            statementCount: run.results.count
        )
    }
}
