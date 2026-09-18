//
//  SQLImportFailure.swift
//  SQLImportPlugin
//

import Foundation
import TableProPluginKit

/// What the user is told when an import fails.
///
/// The cause is the only thing carrying the line number and the failing statement, so a rollback
/// that also fails on the way out is appended to it rather than thrown in its place. Reporting the
/// rollback alone left the user reading "Transaction rollback failed" with nothing about what
/// actually broke, and it turned a cancellation into an error (#2314).
internal enum SQLImportFailure {
    internal static func error(cause: any Error, rollbackError: (any Error)?) -> any Error {
        if cause is PluginImportCancellationError {
            return cause
        }
        guard let rollbackError else {
            return pluginError(for: cause)
        }
        if let pluginError = cause as? PluginImportError,
           case .statementFailed(let statement, let line, let underlyingError) = pluginError {
            return PluginImportError.statementFailed(
                statement: statement,
                line: line,
                underlyingError: RollbackAlsoFailedError(cause: underlyingError, rollbackError: rollbackError)
            )
        }
        return PluginImportError.importFailed(
            RollbackAlsoFailedError(cause: cause, rollbackError: rollbackError).message
        )
    }

    private static func pluginError(for cause: any Error) -> any Error {
        if let pluginError = cause as? PluginImportError {
            return pluginError
        }
        return PluginImportError.importFailed(cause.localizedDescription)
    }
}

internal struct RollbackAlsoFailedError: LocalizedError {
    internal let cause: any Error
    internal let rollbackError: any Error

    /// The database's own message rarely ends in punctuation, so the two are put on separate lines
    /// rather than run together into one unreadable sentence.
    internal var message: String {
        """
        \(cause.localizedDescription)
        The transaction rollback also failed: \(rollbackError.localizedDescription)
        """
    }

    internal var errorDescription: String? { message }
}
