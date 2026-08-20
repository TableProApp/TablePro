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
        }
    }
}
