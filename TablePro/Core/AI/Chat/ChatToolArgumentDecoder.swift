//
//  ChatToolArgumentDecoder.swift
//  TablePro
//

import Foundation

/// Typed decoders for `JsonValue` input arguments coming from the AI.
/// Mirrors `MCPArgumentDecoder` for the MCP protocol but operates on the
/// chat-side `JsonValue` enum.
enum ChatToolArgumentDecoder {
    static func requireString(_ args: JsonValue, key: String) throws -> String {
        guard case .object(let dict) = args, let value = dict[key], case .string(let str) = value else {
            throw ChatToolArgumentError.missingOrInvalid(key: key, expected: "string")
        }
        return str
    }

    static func optionalString(_ args: JsonValue, key: String) -> String? {
        guard case .object(let dict) = args, let value = dict[key], case .string(let str) = value else {
            return nil
        }
        return str
    }

    static func requireUUID(_ args: JsonValue, key: String) throws -> UUID {
        let str = try requireString(args, key: key)
        guard let uuid = UUID(uuidString: str) else {
            throw ChatToolArgumentError.missingOrInvalid(key: key, expected: "UUID string")
        }
        return uuid
    }

    static func optionalBool(_ args: JsonValue, key: String, default fallback: Bool = false) -> Bool {
        guard case .object(let dict) = args, let value = dict[key], case .bool(let bool) = value else {
            return fallback
        }
        return bool
    }

    static func optionalInt(
        _ args: JsonValue,
        key: String,
        default fallback: Int,
        clamp: ClosedRange<Int>? = nil
    ) -> Int? {
        guard case .object(let dict) = args, let value = dict[key] else { return fallback }
        let raw: Int?
        switch value {
        case .int(let int): raw = int
        case .double(let double): raw = Int(double)
        default: raw = nil
        }
        guard let raw else { return fallback }
        if let clamp { return max(clamp.lowerBound, min(raw, clamp.upperBound)) }
        return raw
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
