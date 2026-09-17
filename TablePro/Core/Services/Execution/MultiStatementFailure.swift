//
//  MultiStatementFailure.swift
//  TablePro
//

import Foundation

internal enum MultiStatementFailure: Equatable, Sendable {
    case connection
    case transactionStart
    case statement(sql: String)
    case commit

    func ranStatementCount(executedCount: Int, totalCount: Int) -> Int {
        switch self {
        case .connection, .transactionStart:
            return 0
        case .statement:
            return min(executedCount + 1, totalCount)
        case .commit:
            return executedCount
        }
    }

    func report(executedCount: Int, totalCount: Int, errorDescription: String) -> MultiStatementFailureReport {
        switch self {
        case .connection:
            return MultiStatementFailureReport(
                message: errorDescription,
                resultLabel: String(localized: "Error"),
                failedStatementIndex: nil,
                failedSQL: nil
            )
        case .transactionStart:
            return MultiStatementFailureReport(
                message: String(format: String(localized: "The transaction could not be started: %@"), errorDescription),
                resultLabel: String(localized: "Error"),
                failedStatementIndex: nil,
                failedSQL: nil
            )
        case .statement(let sql):
            let position = min(executedCount + 1, totalCount)
            return MultiStatementFailureReport(
                message: String(
                    format: String(localized: "Statement %1$d/%2$d failed: %3$@"),
                    position, totalCount, errorDescription
                ),
                resultLabel: String(format: String(localized: "Error %d"), position),
                failedStatementIndex: executedCount < totalCount ? executedCount : nil,
                failedSQL: sql
            )
        case .commit:
            return MultiStatementFailureReport(
                message: String(format: String(localized: "The transaction could not be committed: %@"), errorDescription),
                resultLabel: String(localized: "Error"),
                failedStatementIndex: nil,
                failedSQL: nil
            )
        }
    }
}

internal struct MultiStatementFailureReport: Equatable, Sendable {
    let message: String
    let resultLabel: String
    let failedStatementIndex: Int?
    let failedSQL: String?
}
