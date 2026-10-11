//
//  DatabaseDriver+Batches.swift
//  TablePro
//

import Foundation

extension DatabaseDriver {
    /// `query` sent as one batch and read to its end.
    ///
    /// A driver that declared batches and then declines one gets the text as a single statement, which is what it
    /// was sent as before batches existed.
    func answerBatch(query: String, rowCap: Int?, parameters: [Any?]?) async throws -> QueryBatchResult {
        if let answer = try await executeBatch(query: query, rowCap: rowCap, parameters: parameters) {
            return answer
        }
        let single = try await executeUserQuery(query: query, rowCap: rowCap, parameters: parameters)
        return QueryBatchResult(
            resultSets: single.columns.isEmpty ? [] : [single],
            rowsAffected: single.columns.isEmpty ? single.rowsAffected : 0,
            errors: [],
            discardedResultSetCount: 0,
            executionTime: single.executionTime
        )
    }
}
