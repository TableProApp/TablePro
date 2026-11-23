//
//  ChatToolArgumentDecoder.swift
//  TablePro
//

import Foundation
import TableProMCP

enum ChatToolArgumentDecoder {
    // Refused, not ignored: the approval card reads the input, so an ignored key can name a target the call never uses.
    static func rejectUnknownKeys(_ args: JsonValue, declaredBy schema: JsonValue) throws {
        guard case .object(let dict) = args else { return }
        // Undeclared, and `ChatToolTarget` refuses any connection but the session's.
        var allowed: Set<String> = ["connection_id"]
        if case .object(let root) = schema, case .object(let properties)? = root["properties"] {
            allowed.formUnion(properties.keys)
        }
        let unknown = dict.keys.filter { !allowed.contains($0) }.sorted()
        guard unknown.isEmpty else { throw ChatToolArgumentError.unknownKeys(unknown) }
    }

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
        default fallback: Int? = nil,
        clamp: ClosedRange<Int>? = nil
    ) -> Int? {
        guard case .object(let dict) = args, let value = dict[key] else { return fallback }
        let decoded: Int?
        switch value {
        case .int(let int): decoded = int
        case .double(let double): decoded = Int(exactly: double.rounded(.towardZero))
        default: decoded = nil
        }
        guard let raw = decoded ?? fallback else { return nil }
        if let clamp { return max(clamp.lowerBound, min(raw, clamp.upperBound)) }
        return raw
    }
}

enum ChatToolArgumentError: Error, LocalizedError {
    case missingOrInvalid(key: String, expected: String)
    case unknownKeys([String])

    var errorDescription: String? {
        switch self {
        case .missingOrInvalid(let key, let expected):
            return "Argument '\(key)' is missing or not a \(expected)"
        case .unknownKeys(let keys):
            return "Unknown argument(s): \(keys.joined(separator: ", ")). Pass only the arguments this tool declares."
        }
    }
}
