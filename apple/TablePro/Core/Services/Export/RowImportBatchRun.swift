//
//  RowImportBatchRun.swift
//  TablePro
//

import Foundation
import TableProPluginKit

internal struct RowImportRunItem: Sendable, Equatable {
    internal let url: URL
    internal let sourceName: String
    internal let formatId: String
    internal let targetTable: String
    internal let columnMapping: [String: String]
    internal let sourceFields: Set<String>
}

internal struct RowImportBatchPolicy: Sendable, Equatable {
    internal let errorHandling: ImportErrorHandling
    internal let wrapInTransaction: Bool

    internal init(errorHandling: ImportErrorHandling, wrapInTransaction: Bool) {
        self.errorHandling = errorHandling
        self.wrapInTransaction = wrapInTransaction
    }

    internal init(_ configuration: RowImportRunner.Configuration) {
        self.init(errorHandling: configuration.errorHandling, wrapInTransaction: configuration.wrapInTransaction)
    }

    internal var usesTransaction: Bool {
        wrapInTransaction && errorHandling != .skipAndContinue
    }
}

internal struct RowImportBatchReport: Sendable {
    internal enum FileOutcome: Sendable {
        case imported(PluginImportResult)
        case failed(any Error, rowsBefore: Int)
        case stopped(rowsBefore: Int)
        case notRun
    }

    internal enum Ending: Equatable, Sendable {
        case completed
        case failed(file: Int)
        case stopped(file: Int)
    }

    internal let files: [RowImportRunItem]
    internal let outcomes: [FileOutcome]
    internal let ending: Ending
    internal let transaction: ImportTransactionOutcome
    internal let executionTime: TimeInterval
    internal var stopResult: ImportStopResult?

    internal var rowsKept: Bool {
        switch transaction {
        case .rolledBack, .endedByServer:
            return false
        case .untracked, .committed, .committedBeforeRollback, .endedByFile:
            return true
        }
    }

    internal var importedRowCount: Int {
        outcomes.reduce(0) { total, outcome in
            guard case .imported(let result) = outcome else { return total }
            return total + result.executedStatements
        }
    }

    internal var failure: (any Error)? {
        guard case .failed(let index) = ending, case .failed(let error, _) = outcomes[index] else { return nil }
        return error
    }

    internal var hasFailures: Bool {
        outcomes.contains { outcome in
            if case .imported(let result) = outcome { return result.skippedStatements > 0 }
            if case .failed = outcome { return true }
            return false
        }
    }
}
