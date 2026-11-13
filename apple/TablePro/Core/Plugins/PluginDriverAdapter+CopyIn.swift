//
//  PluginDriverAdapter+CopyIn.swift
//  TablePro
//

import Foundation
import TableProPluginKit

extension PluginDriverAdapter {
    var supportsCopyFromStandardInput: Bool {
        schemaPluginDriver.capabilities.contains(.copyFromStandardInput)
    }

    func copyFromStandardInput(
        statement: String,
        rows: PluginCopyData,
        context: PluginStatementContext?
    ) async throws -> QueryResult {
        try StatementTextValidator.validate(statement)
        // The rows come from the editor's text or an imported file, never from an external caller.
        guard supportsCopyFromStandardInput, context?.origin != .external else {
            throw PluginDriverUnsupportedOperation.copyFromStandardInput
        }
        let sent = context.map { statementContext(statement, approvedAs: $0) } ?? statementContext(statement)
        return mapQueryResult(try await schemaPluginDriver.copyFromStandardInput(statement: statement, rows: rows, context: sent))
    }
}
