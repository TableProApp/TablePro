import Foundation

public enum R2SQLJSONValue: Decodable, Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case uint(UInt64)
    case double(Double)
    case string(String)
    case array([R2SQLJSONValue])
    case object([String: R2SQLJSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
            return
        }
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
            return
        }
        if let value = try? container.decode(Int64.self) {
            self = .int(value)
            return
        }
        if let value = try? container.decode(UInt64.self) {
            self = .uint(value)
            return
        }
        if let value = try? container.decode(Double.self) {
            self = .double(value)
            return
        }
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        if let value = try? container.decode([R2SQLJSONValue].self) {
            self = .array(value)
            return
        }
        if let value = try? container.decode([String: R2SQLJSONValue].self) {
            self = .object(value)
            return
        }
        self = .null
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    public var foundationObject: Any {
        switch self {
        case .null:
            return NSNull()
        case .bool(let value):
            return value
        case .int(let value):
            return NSNumber(value: value)
        case .uint(let value):
            return NSNumber(value: value)
        case .double(let value):
            return NSNumber(value: value)
        case .string(let value):
            return value
        case .array(let values):
            return values.map(\.foundationObject)
        case .object(let values):
            return values.mapValues(\.foundationObject)
        }
    }

    public func jsonText() -> String {
        switch self {
        case .null:
            return "null"
        case .bool(let value):
            return value ? "true" : "false"
        case .int(let value):
            return String(value)
        case .uint(let value):
            return String(value)
        case .double(let value):
            return Self.format(double: value)
        case .string(let value):
            return Self.encode(string: value)
        case .array, .object:
            guard let data = try? JSONSerialization.data(
                withJSONObject: foundationObject,
                options: [.sortedKeys, .fragmentsAllowed]
            ), let text = String(data: data, encoding: .utf8) else {
                return ""
            }
            return text
        }
    }

    public var scalarText: String? {
        switch self {
        case .null:
            return nil
        case .bool(let value):
            return value ? "true" : "false"
        case .int(let value):
            return String(value)
        case .uint(let value):
            return String(value)
        case .double(let value):
            return Self.format(double: value)
        case .string(let value):
            return value
        case .array, .object:
            return jsonText()
        }
    }

    static func format(double value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int64(value))
        }
        return String(value)
    }

    static func encode(string value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
              let text = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return text
    }
}
