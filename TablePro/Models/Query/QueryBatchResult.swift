//
//  QueryBatchResult.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// What one batch answered with, read to its end: every complete result set, the rows its other statements
/// counted, and the errors the server raised along the way.
struct QueryBatchResult {
    let resultSets: [QueryResult]
    let rowsAffected: Int
    let errors: [PluginBatchError]
    let discardedResultSetCount: Int
    let executionTime: TimeInterval

    static let empty = QueryBatchResult(
        resultSets: [],
        rowsAffected: 0,
        errors: [],
        discardedResultSetCount: 0,
        executionTime: 0
    )

    /// The result sets one batch keeps across all of its repetitions, the same ceiling the driver keeps for one.
    static let keptResultSetLimit = 100

    /// This answer and `next`, read after it on the same batch, as one answer. `GO 5` sends a batch five times and
    /// keeps what every repetition returned, up to the ceiling one request keeps. An error keeps its place among the
    /// result sets, counted across the repetitions.
    func followed(by next: QueryBatchResult) -> QueryBatchResult {
        let room = max(Self.keptResultSetLimit - resultSets.count, 0)
        let nextErrors = next.errors.map { error in
            PluginBatchError(
                message: error.message,
                code: error.code,
                line: error.line,
                procedure: error.procedure,
                precedingResultSetCount: min(resultSets.count + error.precedingResultSetCount, Self.keptResultSetLimit)
            )
        }
        return QueryBatchResult(
            resultSets: resultSets + next.resultSets.prefix(room),
            rowsAffected: rowsAffected + next.rowsAffected,
            errors: errors + nextErrors,
            discardedResultSetCount: discardedResultSetCount + next.discardedResultSetCount
                + max(next.resultSets.count - room, 0),
            executionTime: executionTime + next.executionTime
        )
    }
}
