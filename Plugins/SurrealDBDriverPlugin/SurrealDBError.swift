//
//  SurrealDBError.swift
//  SurrealDBDriverPlugin
//

import Foundation
import TableProPluginKit

public enum SurrealDBError: PluginDriverError {
    case notConnected
    case invalidEndpoint(String)
    case missingField(String)
    case authenticationFailed(String)
    case unsupportedServerVersion(String)
    case requestFailed(status: Int, message: String)
    case queryFailed(message: String, kind: String?)
    case decodingFailed(String)

    public var pluginErrorMessage: String {
        switch self {
        case .notConnected:
            return String(localized: "Not connected to SurrealDB.")
        case let .invalidEndpoint(endpoint):
            return String(format: String(localized: "Could not build a SurrealDB endpoint from %@."), endpoint)
        case let .missingField(field):
            return String(format: String(localized: "%@ is required for the selected authentication level."), field)
        case let .authenticationFailed(message):
            return message
        case let .unsupportedServerVersion(version):
            return String(
                format: String(localized: "SurrealDB %@ is not supported. TablePro requires SurrealDB 2.0 or later."),
                version
            )
        case let .requestFailed(_, message):
            return message
        case let .queryFailed(message, _):
            return message
        case let .decodingFailed(detail):
            return String(format: String(localized: "Could not read the SurrealDB response: %@"), detail)
        }
    }

    public var pluginErrorCode: String? {
        switch self {
        case let .requestFailed(status, _):
            return String(status)
        case let .queryFailed(_, kind):
            return kind
        default:
            return nil
        }
    }
}
