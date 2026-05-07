//
//  ChatToolArgumentDecoder.swift
//  TablePro
//

import Foundation

/// Typed decoders for `JSONValue` input arguments coming from the AI.
/// Mirrors `MCPArgumentDecoder` for the MCP protocol but operates on the
/// chat-side `JSONValue` enum.
enum ChatToolArgumentDecoder {
    static func requireString(_ args: JSONValue, key: String) throws -> String {
        guard case .object(let dict) = args, let value = dict[key], case .string(let str) = value else {
            throw ChatToolArgumentError.missingOrInvalid(key: key, expected: "string")
        }
        return str
    }

    static func optionalString(_ args: JSONValue, key: String) -> String? {
        guard case .object(let dict) = args, let value = dict[key], case .string(let str) = value else {
            return nil
        }
        return str
    }

    static func requireUUID(_ args: JSONValue, key: String) throws -> UUID {
        let str = try requireString(args, key: key)
        guard let uuid = UUID(uuidString: str) else {
            throw ChatToolArgumentError.missingOrInvalid(key: key, expected: "UUID string")
        }
        return uuid
    }

    static func optionalBool(_ args: JSONValue, key: String, default fallback: Bool = false) -> Bool {
        guard case .object(let dict) = args, let value = dict[key], case .bool(let bool) = value else {
            return fallback
        }
        return bool
    }
}

enum ChatToolArgumentError: Error, LocalizedError {
    case missingOrInvalid(key: String, expected: String)

    var errorDescription: String? {
        switch self {
        case .missingOrInvalid(let key, let expected):
            return "Argument '\(key)' is missing or not a \(expected)"
        }
    }
}
