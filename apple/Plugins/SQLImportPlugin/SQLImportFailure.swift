//
//  SQLImportFailure.swift
//  SQLImportPlugin
//

import Foundation
import TableProPluginKit

internal enum SQLImportFailure {
    internal static func error(cause: any Error, rollbackError: (any Error)?) -> any Error {
        if cause is PluginImportCancellationError || cause is CancellationError {
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

    internal var message: String {
        """
        \(cause.localizedDescription)
        The transaction rollback also failed: \(rollbackError.localizedDescription)
        """
    }

    internal var errorDescription: String? { message }
}
