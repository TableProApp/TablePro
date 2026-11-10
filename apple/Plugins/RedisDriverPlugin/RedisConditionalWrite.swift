//
//  RedisConditionalWrite.swift
//  RedisDriverPlugin
//
//  A write that must not land on a key that already exists.
//

import Foundation
import TableProRedisCore

// `RENAMENX` answers 0 and `SET ... NX` answers nil when the key they would create is already
// there, and neither is an error to the server. A save that sends one has to fail on that answer,
// so the grid wraps the command in `MUSTAPPLY` and the driver reads the reply.
enum RedisConditionalWrite {
    static let keyword = "MUSTAPPLY"

    static func statement(_ command: String) -> String {
        "\(keyword) \(command)"
    }

    // HSET, RPUSH, SADD and ZADD have no create-only form, so a new collection is built under a
    // staging key and moved onto its name with RENAMENX. The staging key starts with the key, so an
    // ACL key pattern that admits the key admits it too.
    static let stagingMarker = ":tablepro-staging:"

    // A cluster takes RENAMENX only within one slot. A key with a hash tag keeps it as the first tag
    // of the staging key; one that hashes whole gets a counter searched to land in its slot, and the
    // suffix has no braces, so it never adds a tag. A counter covers every slot well inside the bound.
    static func stagingKey(for key: String, token: String, partitioned: Bool) -> String? {
        let staging = key + stagingMarker + token
        guard partitioned else { return staging }
        let slot = RedisKeySlot.slot(for: key)
        if RedisKeySlot.slot(for: staging) == slot { return staging }
        for attempt in 0 ..< maxSlotSearch {
            let candidate = "\(staging).\(attempt)"
            if RedisKeySlot.slot(for: candidate) == slot { return candidate }
        }
        return nil
    }

    // The token after the last marker, without the slot counter.
    static func stagingToken(in key: String) -> String? {
        guard let marker = key.range(of: stagingMarker, options: .backwards) else { return nil }
        let token = key[marker.upperBound...].prefix { $0 != "." }
        return token.isEmpty ? nil : String(token)
    }

    // The staging key a failed write leaves behind outside a block, where the save stops before its DEL.
    static func stagingKey(written operation: RedisOperation) -> String? {
        switch operation {
        case .mustApply(let args):
            guard args.count == 3, args[0].text.uppercased() == "RENAMENX" else { return nil }
            return stagingToken(in: args[1].text) == nil ? nil : args[1].text
        case .expire(let key, _):
            return stagingToken(in: key) == nil ? nil : key
        default:
            return nil
        }
    }

    private static let maxSlotSearch = 1_000_000

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
