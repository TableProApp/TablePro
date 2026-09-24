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
}
