import Foundation

enum MCPArgumentDecoder {
    static func requireObject(_ args: JsonValue) throws -> [String: JsonValue] {
        guard case .object(let fields) = args else {
            throw MCPProtocolError.invalidParams(detail: "arguments must be a JSON object")
        }
        return fields
    }

    static func rejectUnknownKeys(_ args: JsonValue, allowed: Set<String>) throws {
        let fields = try requireObject(args)
        let unknown = fields.keys.filter { !allowed.contains($0) }.sorted()
        guard unknown.isEmpty else {
            throw MCPProtocolError.invalidParams(
                detail: "Unknown parameter(s): \(unknown.joined(separator: ", "))"
            )
        }
    }

    static func requireString(_ args: JsonValue, key: String) throws -> String {
        guard let value = args[key], !value.isNull else {
            throw MCPProtocolError.invalidParams(detail: "Missing required parameter: \(key)")
        }
        guard case .string(let string) = value else {
            throw MCPProtocolError.invalidParams(detail: "Parameter '\(key)' must be a string")
        }
        return string
    }

    static func requireNonEmptyString(_ args: JsonValue, key: String) throws -> String {
        let value = try requireString(args, key: key)
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MCPToolExecutionError.invalidArgument("Parameter '\(key)' must not be empty")
        }
        return value
    }

    static func optionalString(_ args: JsonValue, key: String) throws -> String? {
        guard let value = args[key], !value.isNull else { return nil }
        guard case .string(let string) = value else {
            throw MCPProtocolError.invalidParams(detail: "Parameter '\(key)' must be a string")
        }
        return string
    }

    static func requireEnum(_ args: JsonValue, key: String, allowed: [String]) throws -> String {
        let value = try requireString(args, key: key)
        guard allowed.contains(value) else {
            throw MCPToolExecutionError.invalidArgument(
                "Parameter '\(key)' must be one of: \(allowed.sorted().joined(separator: ", "))"
            )
        }
        return value
    }

    static func optionalEnum(_ args: JsonValue, key: String, allowed: [String]) throws -> String? {
        guard let value = try optionalString(args, key: key) else { return nil }
        guard allowed.contains(value) else {
            throw MCPToolExecutionError.invalidArgument(
                "Parameter '\(key)' must be one of: \(allowed.sorted().joined(separator: ", "))"
            )
        }
        return value
    }

    static func requireUuid(_ args: JsonValue, key: String) throws -> UUID {
        let raw = try requireString(args, key: key)
        guard let uuid = UUID(uuidString: raw) else {
            throw MCPToolExecutionError.invalidArgument("Parameter '\(key)' is not a valid UUID")
        }
        return uuid
    }

    static func optionalUuid(_ args: JsonValue, key: String) throws -> UUID? {
        guard let raw = try optionalString(args, key: key) else { return nil }
        guard let uuid = UUID(uuidString: raw) else {
            throw MCPToolExecutionError.invalidArgument("Parameter '\(key)' is not a valid UUID")
        }
        return uuid
    }

    static func requireInt(_ args: JsonValue, key: String, range: ClosedRange<Int>? = nil) throws -> Int {
        guard let value = args[key], !value.isNull else {
            throw MCPProtocolError.invalidParams(detail: "Missing required parameter: \(key)")
        }
        return try integer(from: value, key: key, range: range)
    }

    static func optionalInt(
        _ args: JsonValue,
        key: String,
        range: ClosedRange<Int>? = nil
    ) throws -> Int? {
        guard let value = args[key], !value.isNull else { return nil }
        return try integer(from: value, key: key, range: range)
    }

    static func optionalBool(_ args: JsonValue, key: String, default defaultValue: Bool) throws -> Bool {
        guard let value = args[key], !value.isNull else { return defaultValue }
        guard case .bool(let flag) = value else {
            throw MCPProtocolError.invalidParams(detail: "Parameter '\(key)' must be a boolean")
        }
        return flag
    }

    static func optionalDouble(_ args: JsonValue, key: String) throws -> Double? {
        guard let value = args[key], !value.isNull else { return nil }
        guard let number = value.doubleValue else {
            throw MCPProtocolError.invalidParams(detail: "Parameter '\(key)' must be a number")
        }
        return number
    }

    static func optionalStringArray(_ args: JsonValue, key: String) throws -> [String]? {
        guard let value = args[key], !value.isNull else { return nil }
        guard case .array(let items) = value else {
            throw MCPProtocolError.invalidParams(detail: "Parameter '\(key)' must be an array of strings")
        }
        var strings: [String] = []
        for item in items {
            guard case .string(let string) = item else {
                throw MCPProtocolError.invalidParams(
                    detail: "Parameter '\(key)' must contain only strings"
                )
            }
            strings.append(string)
        }
        return strings
    }

    static func optionalObjectArray(_ args: JsonValue, key: String) throws -> [[String: JsonValue]]? {
        guard let value = args[key], !value.isNull else { return nil }
        guard case .array(let items) = value else {
            throw MCPProtocolError.invalidParams(detail: "Parameter '\(key)' must be an array of objects")
        }
        var objects: [[String: JsonValue]] = []
        for item in items {
            guard case .object(let fields) = item else {
                throw MCPProtocolError.invalidParams(
                    detail: "Parameter '\(key)' must contain only objects"
                )
            }
            objects.append(fields)
        }
        return objects
    }

    private static func integer(from value: JsonValue, key: String, range: ClosedRange<Int>?) throws -> Int {
        let resolved: Int
        switch value {
        case .int(let number):
            resolved = number
        case .double(let number) where number == number.rounded() && number.magnitude < Double(Int.max):
            resolved = Int(number)
        default:
            throw MCPProtocolError.invalidParams(detail: "Parameter '\(key)' must be an integer")
        }
        guard let range else { return resolved }
        guard range.contains(resolved) else {
            throw MCPToolExecutionError.invalidArgument(
                "Parameter '\(key)' must be between \(range.lowerBound) and \(range.upperBound)"
            )
        }
        return resolved
    }
}
