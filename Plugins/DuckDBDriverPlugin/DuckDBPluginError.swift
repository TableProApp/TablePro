//
//  DuckDBPluginError.swift
//  DuckDBDriverPlugin
//

import Foundation
import TableProPluginKit

enum DuckDBPluginError: Error {
    case connectionFailed(String)
    case notConnected
    case queryFailed(String)
    case unsupportedOperation
}

extension DuckDBPluginError: PluginDriverError {
    var pluginErrorMessage: String {
        switch self {
        case .connectionFailed(let msg): return msg
        case .notConnected: return String(localized: "Not connected to database")
        case .queryFailed(let msg): return msg
        case .unsupportedOperation: return String(localized: "Operation not supported")
        }
    }
}
