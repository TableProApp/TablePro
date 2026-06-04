//
//  SnowflakeError.swift
//  SnowflakeDriverPlugin
//

import Foundation
import TableProPluginKit

enum SnowflakeError: Error, LocalizedError {
    case notConnected
    case authFailed(String)
    case loginFailed(code: String, message: String)
    case queryFailed(code: String, message: String)
    case invalidResponse(String)
    case timeout(String)
    case cancelled
    case configuration(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return String(localized: "Not connected to Snowflake")
        case .authFailed(let detail):
            return detail
        case .loginFailed(let code, let message):
            return code.isEmpty ? message : "\(message) (\(code))"
        case .queryFailed(let code, let message):
            return code.isEmpty ? message : "\(message) (\(code))"
        case .invalidResponse(let detail):
            return detail
        case .timeout(let detail):
            return detail
        case .cancelled:
            return String(localized: "Query was cancelled")
        case .configuration(let detail):
            return detail
        }
    }
}

extension SnowflakeError: PluginDriverError {
    var pluginErrorMessage: String {
        errorDescription ?? String(localized: "Unknown Snowflake error")
    }

    var pluginErrorCode: Int? {
        switch self {
        case .loginFailed(let code, _), .queryFailed(let code, _):
            return Int(code)
        default:
            return nil
        }
    }
}
