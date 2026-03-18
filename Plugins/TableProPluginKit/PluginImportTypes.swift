//
//  PluginImportTypes.swift
//  TableProPluginKit
//

import Foundation

public struct PluginImportResult: Sendable {
    public let executedStatements: Int
    public let executionTime: TimeInterval
    public let failedStatement: String?
    public let failedLine: Int?

    public init(
        executedStatements: Int,
        executionTime: TimeInterval,
        failedStatement: String? = nil,
        failedLine: Int? = nil
    ) {
        self.executedStatements = executedStatements
        self.executionTime = executionTime
        self.failedStatement = failedStatement
        self.failedLine = failedLine
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
