//
//  DatabaseDriver+StatementBatches.swift
//  TablePro
//

import Foundation
import TableProPluginKit

struct BatchedStatement: @unchecked Sendable {
    let sql: String
    // Nil runs the text as `execute(query:)` does, an array binds it as `executeParameterized` does.
    let parameters: [Any?]?
    // Nil runs it as the call without a context does.
    let context: PluginStatementContext?

    init(sql: String, parameters: [Any?]? = nil, context: PluginStatementContext? = nil) {
        self.sql = sql
        self.parameters = parameters
        self.context = context
    }
}

enum BatchedStatementOutcome: Sendable {
    case succeeded(rowsAffected: Int, executionTime: TimeInterval)
    case failed(any Error)

    init(_ outcome: PluginBatchStatementOutcome) {
        switch outcome {
        case .succeeded(let rowsAffected, let executionTime):
            self = .succeeded(rowsAffected: rowsAffected, executionTime: executionTime)
        case .failed(let error):
            self = .failed(error)
        @unknown default:
            self = .failed(DatabaseError.queryFailed(
                String(localized: "The driver answered a statement in a way this version of TablePro cannot read.")
            ))
        }
    }

    var succeeded: Bool {
        if case .succeeded = self { return true }
        return false
    }
}

extension DatabaseDriver {
    // In order, stopping at the first failure as a loop sending each in turn stops: one outcome per statement sent.
    func runStatements(_ statements: [BatchedStatement]) async -> [BatchedStatementOutcome] {
        if supportsStatementBatches, statements.count > 1 {
            do {
                if let outcomes = try await executeStatements(statements) { return outcomes }
            } catch {
                return [.failed(error)]
            }
        }
        var outcomes: [BatchedStatementOutcome] = []
        for statement in statements {
            let startedAt = Date()
            do {
                let result = try await runAlone(statement)
                outcomes.append(.succeeded(
                    rowsAffected: result.rowsAffected,
                    executionTime: Date().timeIntervalSince(startedAt)
                ))
            } catch {
                outcomes.append(.failed(error))
                break
            }
        }
        return outcomes
    }

    func runAlone(_ statement: BatchedStatement) async throws -> QueryResult {
        switch (statement.parameters, statement.context) {
        case (nil, nil):
            return try await execute(query: statement.sql)
        case (nil, let context?):
            return try await execute(query: statement.sql, context: context)
        case (let parameters?, nil):
            return try await executeParameterized(query: statement.sql, parameters: parameters)
        case (let parameters?, let context?):
            return try await executeParameterized(query: statement.sql, parameters: parameters, context: context)
        }
    }
}
