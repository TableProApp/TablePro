import Foundation

enum MCPArgumentDecoder {
    static func requireString(_ args: JsonValue, key: String) throws -> String {
        guard case .string(let value) = args[key] else {
            throw MCPProtocolError.invalidParams(detail: "Missing required parameter: \(key)")
        }
        return value
    }

    static func optionalString(_ args: JsonValue, key: String) -> String? {
        guard case .string(let value) = args[key] else { return nil }
        return value
    }

    static func requireUuid(_ args: JsonValue, key: String) throws -> UUID {
        let raw = try requireString(args, key: key)
        guard let uuid = UUID(uuidString: raw) else {
            throw MCPProtocolError.invalidParams(detail: "Invalid UUID for parameter: \(key)")
        }
        return uuid
    }

    static func optionalUuid(_ args: JsonValue, key: String) throws -> UUID? {
        guard let raw = optionalString(args, key: key) else { return nil }
        guard let uuid = UUID(uuidString: raw) else {
            throw MCPProtocolError.invalidParams(detail: "Invalid UUID for parameter: \(key)")
        }
        return uuid
    }

    static func requireInt(_ args: JsonValue, key: String) throws -> Int {
        guard let value = args[key]?.intValue else {
            throw MCPProtocolError.invalidParams(detail: "Missing required parameter: \(key)")
        }
        return value
    }

    static func optionalInt(
        _ args: JsonValue,
        key: String,
        default defaultValue: Int? = nil,
        clamp: ClosedRange<Int>? = nil
    ) -> Int? {
        let raw = args[key]?.intValue
        guard let raw else { return defaultValue }
        guard let clamp else { return raw }
        return min(max(raw, clamp.lowerBound), clamp.upperBound)
    }

    static func optionalBool(_ args: JsonValue, key: String, default defaultValue: Bool = false) -> Bool {
        args[key]?.boolValue ?? defaultValue
    }

    static func optionalDouble(_ args: JsonValue, key: String) -> Double? {
        args[key]?.doubleValue
    }

    static func optionalStringArray(_ args: JsonValue, key: String) -> [String]? {
        guard let array = args[key]?.arrayValue else { return nil }
        let strings = array.compactMap { $0.stringValue }
        return strings.isEmpty ? nil : strings
    }
}
