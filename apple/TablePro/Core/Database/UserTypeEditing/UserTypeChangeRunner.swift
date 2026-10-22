//
//  UserTypeChangeRunner.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit
import TableProSQLGrammar

/// The statements a type's queued changes run, each step tied to the change it came from.
struct UserTypeChangePlan: Equatable, Sendable {
    struct Step: Equatable, Sendable {
        let changeId: UUID
        let statements: [String]
    }

    let steps: [Step]
    let isDestructive: Bool
    /// The driver says a statement here is refused inside a transaction block on this server.
    var runsOutsideTransaction = false

    var statements: [String] { steps.flatMap(\.statements) }

    enum BuildError: LocalizedError, Equatable {
        case unsupported(String)

        var errorDescription: String? {
            switch self {
            case .unsupported(let summary):
                String(format: String(localized: "This database cannot make the change “%@”."), summary)
            }
        }
    }

    /// Every change is addressed by the type's server name, so a rename has to be the last step:
    /// the editor keeps it at the end of the queue for that reason.
    static func build(
        type: UserDefinedTypeInfo,
        changes: [StagedTypeChange],
        driver: DatabaseDriver
    ) throws -> UserTypeChangePlan {
        let steps = try changes.map { staged -> Step in
            guard let statements = driver.alterUserDefinedTypeStatements(type: type, change: staged.change),
                  !statements.isEmpty
            else { throw BuildError.unsupported(staged.summary) }
            return Step(changeId: staged.id, statements: statements)
        }
        return UserTypeChangePlan(
            steps: steps,
            isDestructive: changes.contains(where: \.isDestructive),
            runsOutsideTransaction: changes.contains { driver.userDefinedTypeChangeRunsOutsideTransaction($0.change) }
        )
    }
}

enum UserTypeSaveOutcome: Equatable, Sendable {
    case applied
    /// The server refused one change. `applied` lists the changes before it that stand: none when
    /// the save ran in a transaction and was rolled back.
    case failed(changeId: UUID, message: String, applied: [UUID])
}

@MainActor
enum UserTypeChangeRunner {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "UserTypeChangeRunner")

    /// No transaction on the session driver, where BEGIN would join a query tab's open one, nor
    /// around a statement the server refuses inside one (ADD VALUE before PostgreSQL 12).
    static func run(
        _ plan: UserTypeChangePlan,
        in scope: DatabaseScope,
        connection: DatabaseConnection,
        operationDescription: String = String(localized: "Save Type Changes"),
        gate: any ExecutionGate = ExecutionGateProvider.shared
    ) async throws -> UserTypeSaveOutcome {
        let statements = plan.statements
        guard !statements.isEmpty else { return .applied }

        let decision = await gate.authorize(
            OperationRequest(
                connectionId: connection.id,
                databaseType: connection.type,
                sql: statements.joined(separator: ";\n"),
                kind: plan.isDestructive ? .destructiveQuery : .schemaMutation,
                caller: .userInterface,
                capabilities: .interactiveUser,
                operationDescription: operationDescription
            )
        )
        if let denial = decision.denialError { throw denial }

        let databaseType = connection.type
        let refusesTransaction = plan.runsOutsideTransaction
        let route = DatabaseManager.shared.schemaChangeRoute(for: scope)
        let startedAt = Date()
        let result = try await DatabaseManager.shared.withScopedDriver(
            scope: scope,
            route: route,
            cancellation: .protectedWrite
        ) { driver in
            let useTransaction = route.isPooled
                && DatabaseManager.wrapsDDLInTransaction(driver)
                && !refusesTransaction
            return await Self.execute(plan.steps, on: driver, useTransaction: useTransaction)
        }

        if !result.ran.isEmpty {
            await DatabaseManager.shared.historyRecorder.record(
                QueryHistoryRecordRequest(
                    query: result.ran.map { $0.hasSuffix(";") ? $0 : $0 + ";" }.joined(separator: "\n"),
                    connectionId: connection.id,
                    databaseName: scope.database,
                    databaseType: databaseType,
                    schemaName: scope.schema,
                    source: .structureDDL,
                    executionTime: Date().timeIntervalSince(startedAt),
                    rowCount: -1,
                    wasSuccessful: true
                )
            )
        }
        if !result.ran.isEmpty {
            CatalogChangeService.shared.record(
                .changed(CatalogChange(connectionId: connection.id, database: scope.database, kinds: .types))
            )
        }
        return result.outcome
    }

    private struct Execution: Sendable {
        let outcome: UserTypeSaveOutcome
        /// The statements that stand on the server.
        let ran: [String]
    }

    nonisolated private static func execute(
        _ steps: [UserTypeChangePlan.Step],
        on driver: DatabaseDriver,
        useTransaction: Bool
    ) async -> Execution {
        var ran: [String] = []
        var applied: [UUID] = []
        do {
            if useTransaction { try await driver.beginTransaction(mode: .readWrite) }
        } catch {
            guard let first = steps.first else { return Execution(outcome: .applied, ran: []) }
            return Execution(
                outcome: .failed(changeId: first.changeId, message: error.localizedDescription, applied: []),
                ran: []
            )
        }
        for step in steps {
            do {
                for statement in step.statements {
                    _ = try await driver.execute(query: statement)
                    ran.append(statement)
                }
                applied.append(step.changeId)
            } catch {
                let message = error.localizedDescription
                guard useTransaction else {
                    return Execution(
                        outcome: .failed(changeId: step.changeId, message: message, applied: applied),
                        ran: ran
                    )
                }
                await rollBack(driver)
                return Execution(outcome: .failed(changeId: step.changeId, message: message, applied: []), ran: [])
            }
        }
        if useTransaction {
            do {
                try await driver.commitTransaction()
            } catch {
                await rollBack(driver)
                let last = steps.last?.changeId ?? UUID()
                return Execution(outcome: .failed(changeId: last, message: error.localizedDescription, applied: []), ran: [])
            }
        }
        return Execution(outcome: .applied, ran: ran)
    }

    nonisolated private static func rollBack(_ driver: DatabaseDriver) async {
        do {
            try await driver.rollbackTransaction()
        } catch {
            logger.error("Rollback after a refused type change failed: \(error.publicLogShape, privacy: .public)")
        }
    }
}
