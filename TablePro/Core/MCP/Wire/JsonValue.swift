import Foundation

public enum JsonValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JsonValue])
    case object([String: JsonValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
            return
        }

        if let boolValue = try? container.decode(Bool.self) {
            self = .bool(boolValue)
            return
        }

        if let intValue = try? container.decode(Int.self) {
            self = .int(intValue)
            return
        }

        if let doubleValue = try? container.decode(Double.self) {
            self = .double(doubleValue)
            return
        }

        if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
            return
        }

        if let arrayValue = try? container.decode([JsonValue].self) {
            self = .array(arrayValue)
            return
        }

        if let objectValue = try? container.decode([String: JsonValue].self) {
            self = .object(objectValue)
            return
        }

        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode JsonValue")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

extension JsonValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .string(value)
    }
}

extension JsonValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) {
        self = .int(value)
    }
}

extension JsonValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) {
        self = .double(value)
    }
}

extension JsonValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) {
        self = .bool(value)
    }
}

extension JsonValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) {
        self = .null
    }
}

extension JsonValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JsonValue...) {
        self = .array(elements)
    }
}

extension JsonValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JsonValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}

public extension JsonValue {
    subscript(key: String) -> JsonValue? {
        guard case .object(let dict) = self else { return nil }
        return dict[key]
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var intValue: Int? {
        guard case .int(let value) = self else { return nil }
        return value
    }

    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    var doubleValue: Double? {
        switch self {
        case .double(let value):
            return value
        case .int(let value):
            return Double(value)
        default:
            return nil
        }
    }

    var arrayValue: [JsonValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var objectValue: [String: JsonValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }
}
