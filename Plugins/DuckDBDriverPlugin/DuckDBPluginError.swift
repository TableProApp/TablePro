//
//  DuckDBPluginError.swift
//  DuckDBDriverPlugin
//

import Foundation
import TableProPluginKit

enum DuckDBPluginError: Error {
    case connectionFailed(String)
    case notConnected
    case catalogUnresolved
    case queryFailed(String)
    case unsupportedOperation
    case fileLocked(DuckDBLockConflict)
    case fileMissing(String)
}

extension DuckDBPluginError: PluginDriverError {
    var pluginErrorMessage: String {
        switch self {
        case .connectionFailed(let msg): return msg
        case .notConnected: return String(localized: "Not connected to database")
        case .catalogUnresolved:
            return String(localized: "The connection has no current DuckDB catalog to read metadata from")
        case .queryFailed(let msg): return msg
        case .unsupportedOperation: return String(localized: "Operation not supported")
        case .fileLocked(let conflict):
            guard let suggestion = conflict.recoverySuggestion else { return conflict.localizedDescription }
            return "\(conflict.localizedDescription) \(suggestion)"
        case .fileMissing(let path):
            return String(
                format: String(localized: "The database file is no longer at %@."),
                path
            )
        }
    }
}
