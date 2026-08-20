//
//  RedisReply.swift
//  RedisDriverPlugin
//
//  The structured form of a Redis server response, and the driver's error type.
//  Kept apart from the hiredis connection so the routing and aggregation logic that reads
//  replies can be compiled and tested without the C library.
//

import Foundation
import TableProPluginKit

// MARK: - Reply Type

enum RedisReply {
    case string(String)
    case integer(Int64)
    case array([RedisReply])
    case data(Data)
    case status(String)
    case error(String)
    case null

    var stringValue: String? {
        switch self {
        case .string(let s), .status(let s): return s
        case .data(let d): return String(data: d, encoding: .utf8)
        default: return nil
        }
    }

    var intValue: Int? {
        switch self {
        case .integer(let i): return Int(i)
        case .string(let s): return Int(s)
        default: return nil
        }
    }

    var stringArrayValue: [String]? {
        guard case .array(let items) = self else { return nil }
        return items.compactMap(\.stringValue)
    }

    var arrayValue: [RedisReply]? {
        guard case .array(let items) = self else { return nil }
        return items
    }

    var isError: Bool {
        if case .error = self { return true }
        return false
    }

    var errorMessage: String? {
        guard case .error(let message) = self else { return nil }
        return message
    }

    /// hiredis hands a server error back as an ordinary reply with `ctx->err == 0`, so nothing
    /// throws unless a caller looks. Every path that acts on a reply has to call this or it will
    /// report success for a command the server refused.
    @discardableResult
    func throwIfError(_ context: @autoclosure () -> String = "") throws -> RedisReply {
        guard case .error(let message) = self else { return self }
        let label = context()
        throw RedisPluginError(code: 0, message: label.isEmpty ? message : "\(label): \(message)")
    }
}

// MARK: - Error Type

struct RedisPluginError: Error {
    let code: Int
    let message: String

    static let notConnected = RedisPluginError(code: 0, message: String(localized: "Not connected to Redis"))
    static let connectionFailed = RedisPluginError(code: 0, message: String(localized: "Failed to establish connection"))
    static let hiredisUnavailable = RedisPluginError(
        code: 0,
        message: String(localized: "Redis support requires hiredis. Run scripts/build-hiredis.sh first.")
    )
}

extension RedisPluginError: PluginDriverError {
    var pluginErrorMessage: String { message }
    var pluginErrorCode: Int? { code }
}

/// A connection-level failure that records which side of the exchange it happened on.
///
/// hiredis reports a read timeout with the same REDIS_ERR_IO it uses for a failed write, so the
/// error code alone cannot say whether the server ran the command. Splitting the write from the
/// read is the only way to know, and knowing is what makes an automatic replay safe.
struct RedisTransportFailure: Error {
    let code: Int
    let message: String
    let wasDelivered: Bool
}

extension RedisTransportFailure: PluginDriverError {
    var pluginErrorMessage: String { message }
    var pluginErrorCode: Int? { code }
}
