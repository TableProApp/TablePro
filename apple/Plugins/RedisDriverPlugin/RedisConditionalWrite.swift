//
//  RedisConditionalWrite.swift
//  RedisDriverPlugin
//
//  A write that must not land on a key that already exists.
//

import Foundation

// `RENAMENX` answers 0 and `SET ... NX` answers nil when the key they would create is already
// there, and neither is an error to the server. A save that sends one has to fail on that answer,
// so the grid wraps the command in `MUSTAPPLY` and the driver reads the reply.
enum RedisConditionalWrite {
    static let keyword = "MUSTAPPLY"

    static func statement(_ command: String) -> String {
        "\(keyword) \(command)"
    }

    static func applied(_ reply: RedisReply) -> Bool {
        switch reply {
        case .null: return false
        case .integer(let value): return value != 0
        default: return true
        }
    }

    static var refusedMessage: String {
        String(localized: "A key with this name already exists.")
    }

    static func command(in statement: String) -> String? {
        let prefix = "\(keyword) "
        return statement.hasPrefix(prefix) ? String(statement.dropFirst(prefix.count)) : nil
    }
}

extension RedisOperation {
    var mustApply: Bool {
        switch self {
        case .mustApply: return true
        case .inDatabase(_, let operation): return operation.mustApply
        default: return false
        }
    }
}
