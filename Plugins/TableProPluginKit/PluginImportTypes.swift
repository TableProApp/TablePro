//
//  PluginImportTypes.swift
//  TableProPluginKit
//

import Foundation

public enum ImportErrorHandling: String, Codable, CaseIterable, Sendable {
    case stopAndRollback
    case stopAndCommit
    case skipAndContinue
}

public struct PluginImportResult: Sendable {
    public let executedStatements: Int
    public let skippedStatements: Int
    public let executionTime: TimeInterval
    public let errors: [ImportStatementError]

    public init(
        executedStatements: Int,
        executionTime: TimeInterval,
        skippedStatements: Int = 0,
        errors: [ImportStatementError] = []
    ) {
        self.executedStatements = executedStatements
        self.skippedStatements = skippedStatements
        self.executionTime = executionTime
        self.errors = errors
    }
}

public extension PluginImportResult {
    struct ImportStatementError: Sendable {
        public let statement: String
        public let line: Int
        public let errorMessage: String

        public init(statement: String, line: Int, errorMessage: String) {
            self.statement = statement
            self.line = line
            self.errorMessage = errorMessage
        }
    }
}

public enum PluginImportError: LocalizedError {
    case statementFailed(statement: String, line: Int, underlyingError: any Error)
    case rollbackFailed(underlyingError: any Error)
    case cancelled
    case importFailed(String)

    public var errorDescription: String? {
        switch self {
        case .statementFailed(_, let line, let error):
            return "Import failed at line \(line): \(error.localizedDescription)"
        case .rollbackFailed(let error):
            return "Transaction rollback failed: \(error.localizedDescription)"
        case .cancelled:
            return "Import cancelled"
        case .importFailed(let message):
            return "Import failed: \(message)"
        }
    }
}

public struct PluginImportCancellationError: Error, LocalizedError {
    public init() {}
    public var errorDescription: String? { "Import cancelled" }
}
