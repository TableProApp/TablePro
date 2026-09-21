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

    /// An error element is marked the way `redis-cli` marks one, because `EXEC` answers with the
    /// failures of the block inline among its values: an unmarked `WRONGTYPE Operation against a
    /// key holding the wrong kind of value` in a result row reads as a stored string.
    var displayText: String {
        switch self {
        case .string(let text), .status(let text): return text
        case .error(let message): return "(error) \(message)"
        case .integer(let value): return String(value)
        case .data(let bytes): return String(data: bytes, encoding: .utf8) ?? bytes.base64EncodedString()
        case .array(let items): return "[\(items.map(\.displayText).joined(separator: ", "))]"
        case .null: return "(nil)"
        }
    }

    var isError: Bool {
        if case .error = self { return true }
        return false
    }

    var errorMessage: String? {
        guard case .error(let message) = self else { return nil }
        return message
    }

    /// A `+QUEUED` simple string, which is what Redis answers for every command it holds in an open
    /// `MULTI` block instead of that command's own reply.
    ///
    /// The reply *shape* is the signal, not the text: measured over raw RESP on Redis 8.10.1, a
    /// queued command answers `+QUEUED\r\n` while a `GET` of a key holding the word arrives as the
    /// bulk string `$6\r\nQUEUED`. A command can also answer `+QUEUED` outside any block (`EVAL
    /// "return redis.status_reply('QUEUED')" 0`, measured, byte for byte the same), which nothing
    /// in the driver sends.
    var isQueued: Bool {
        guard case .status(let value) = self else { return false }
        return value == "QUEUED"
    }

    /// A queued reply is the block's acknowledgement, never the command's answer, so every caller
    /// that reads a value out of one reads the acknowledgement instead: `GET` returned "QUEUED" as
    /// the stored value, `DEL` counted zero deletions, `LPUSH` reported length zero and `DBSIZE`
    /// reported an empty keyspace.
    @discardableResult
    func throwIfQueued(_ command: @autoclosure () -> String) throws -> RedisReply {
        guard isQueued else { return self }
        throw RedisQueuedCommand(command: command())
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
    let detail: String?
    /// True when the server answered and said no. A node that rejects credentials is a
    /// configuration problem, and reporting it as unreachable sends the user to the wrong field.
    let refusedByServer: Bool

    init(code: Int, message: String, detail: String? = nil, refusedByServer: Bool = false) {
        self.code = code
        self.message = message
        self.detail = detail
        self.refusedByServer = refusedByServer
    }

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
    var pluginErrorDetail: String? { detail }
}

/// A command the server queued instead of running, because a `MULTI` block is open on the session.
struct RedisQueuedCommand: Error, Equatable {
    let command: String
}

extension RedisQueuedCommand: PluginDriverError {
    var pluginErrorMessage: String {
        String(
            format: String(localized: "Redis queued %@ instead of running it."),
            command.isEmpty ? String(localized: "the command") : command
        )
    }

    var pluginErrorDetail: String? {
        String(localized: "A MULTI block is open on this connection. Run EXEC to apply it, or DISCARD to drop it.")
    }
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
