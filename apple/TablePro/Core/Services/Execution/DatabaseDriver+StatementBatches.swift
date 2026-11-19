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
