//
//  CassandraPluginError.swift
//  CassandraDriverPlugin
//

import Foundation
import TableProPluginKit

internal enum CassandraPluginError: Error {
    case connectionFailed(String)
    case notConnected
    case queryFailed(String)
    case unsupportedOperation
}

extension CassandraPluginError {
    /// The server refuses to page a read that restricts the partition key with `IN` and orders by a clustering
    /// column, so that read has to be sent unpaged.
    var refusesPaging: Bool {
        guard case .queryFailed(let message) = self else { return false }
        return message.contains("Cannot page queries")
    }
}

extension CassandraPluginError: PluginDriverError {
    var pluginErrorMessage: String {
        switch self {
        case .connectionFailed(let msg): return msg
        case .notConnected: return String(localized: "Not connected to database")
        case .queryFailed(let msg): return msg
        case .unsupportedOperation: return String(localized: "Operation not supported by Cassandra")
        }
    }
}
