//
//  PluginDriverError.swift
//  TableProPluginKit
//

import Foundation

public protocol PluginDriverError: LocalizedError, Sendable {
    var pluginErrorMessage: String { get }
    var pluginErrorCode: Int? { get }
    var pluginSqlState: String? { get }
    var pluginErrorDetail: String? { get }
}

public extension PluginDriverError {
    var pluginErrorCode: Int? { nil }
    var pluginSqlState: String? { nil }
    var pluginErrorDetail: String? { nil }

    var errorDescription: String? {
        var desc = pluginErrorMessage
        if let code = pluginErrorCode, code != 0 {
            desc = "[\(code)] \(desc)"
        }
        if let state = pluginSqlState {
            desc += " (SQLSTATE: \(state))"
        }
        if let detail = pluginErrorDetail, !detail.isEmpty {
            desc += "\nDetail: \(detail)"
        }
        return desc
    }
}

// A statement Stop ended, after which the server rolled back the transaction it ran in. A driver throws it in place of
// the cancellation, so the host can say what the Stop undid.
public struct PluginStopRolledBackTransaction: PluginDriverError {
    public let pluginErrorCode: Int?

    public init(code: Int? = nil) {
        pluginErrorCode = code
    }

    public var pluginErrorMessage: String {
        String(localized: "The statement was stopped, and the server rolled back the transaction it ran in. Every change since that transaction began is undone.")
    }
}
