//
//  MainContentCoordinator+MultiStatement.swift
//  TablePro
//

import Foundation

extension MainContentCoordinator {
    func executeMultipleStatements(_ statements: [String]) {
        queryExecutionCoordinator.executeMultipleStatements(statements)
    }

    internal func applyMultiStatementResults(
        tabId: UUID,
        capturedGeneration: Int,
        cumulativeTime: TimeInterval,
        totalRowsAffected: Int,
        lastSelectResult: QueryResult?,
        lastSelectSQL: String?,
        newResultSets: [ResultSet]
    ) {
        queryExecutionCoordinator.applyMultiStatementResults(
            tabId: tabId,
            capturedGeneration: capturedGeneration,
            cumulativeTime: cumulativeTime,
            totalRowsAffected: totalRowsAffected,
            lastSelectResult: lastSelectResult,
            lastSelectSQL: lastSelectSQL,
            newResultSets: newResultSets
        )
    }
}
