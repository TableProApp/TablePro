import Foundation

nonisolated internal enum RedisReplyValue: Sendable, Equatable {
    case string(String)
    case integer(Int64)
    case array([RedisReplyValue])
    case status(String)
    case error(String)
    case null

    var stringRepresentation: String? {
        switch self {
        case .string(let s): return s
        case .integer(let i): return String(i)
        case .status(let s): return s
        case .error(let s): return "(error) \(s)"
        case .null: return nil
        case .array(let items): return "[\(items.compactMap(\.stringRepresentation).joined(separator: ", "))]"
        }
    }

    var stringElements: [String] {
        guard case .array(let items) = self else { return [] }
        return items.compactMap { item in
            switch item {
            case .string(let value), .status(let value):
                return value
            default:
                return nil
            }
        }
    }

    var errorMessage: String? {
        guard case .error(let message) = self else { return nil }
        return message
    }

    /// Measured on Redis 8.10.1: a command held in an open `MULTI` block answers the simple string
    /// `+QUEUED`, while a `GET` of a key holding that word answers the bulk string, so only the
    /// status shape means the command did not run.
    var isQueued: Bool {
        guard case .status(let value) = self else { return false }
        return value == "QUEUED"
    }

    @discardableResult
    func throwIfError() throws -> RedisReplyValue {
        guard case .error(let message) = self else { return self }
        throw RedisError.queryFailed(message)
    }

    @discardableResult
    func throwIfQueued(_ command: String) throws -> RedisReplyValue {
        guard isQueued else { return self }
        throw RedisError.commandQueued(command)
    }
}
