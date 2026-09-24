//
//  QueryBatchResultTests.swift
//  TableProTests
//
//  `GO n` sends a batch n times, and the editor and every external caller fold the answers into one with
//  `followed(by:)`, so the ceiling, the counts and the place of each error are decided in one place.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Answers of a repeated batch")
struct QueryBatchResultTests {
    private func answer(resultSets: Int, rowsAffected: Int = 0, errorAfter: Int? = nil) -> QueryBatchResult {
        QueryBatchResult(
            resultSets: (0..<resultSets).map { index in
                QueryResult(columns: ["c\(index)"], columnTypes: [], rows: [], rowsAffected: 0, executionTime: 0, error: nil)
            },
            rowsAffected: rowsAffected,
            errors: errorAfter.map { preceding in
                [PluginBatchError(message: "boom", code: 50_000, line: 1, procedure: nil, precedingResultSetCount: preceding)]
            } ?? [],
            discardedResultSetCount: 0,
            executionTime: 0.5
        )
    }

    @Test("Counts and time add up across repetitions")
    func countsAddUp() {
        let combined = answer(resultSets: 1, rowsAffected: 2).followed(by: answer(resultSets: 2, rowsAffected: 3))

        #expect(combined.resultSets.map(\.columns) == [["c0"], ["c0"], ["c1"]])
        #expect(combined.rowsAffected == 5)
        #expect(combined.executionTime == 1)
        #expect(combined.discardedResultSetCount == 0)
    }

    @Test("Result sets past the ceiling are counted as discarded rather than kept")
    func ceilingIsKept() {
        let limit = QueryBatchResult.keptResultSetLimit
        let combined = answer(resultSets: limit - 1).followed(by: answer(resultSets: 3))

        #expect(combined.resultSets.count == limit)
        #expect(combined.discardedResultSetCount == 2)
    }

    @Test("An error in a later repetition counts the result sets of the ones before it")
    func errorKeepsItsPlace() {
        let combined = answer(resultSets: 2).followed(by: answer(resultSets: 1, errorAfter: 1))

        #expect(combined.errors.map(\.precedingResultSetCount) == [3])
    }
}
