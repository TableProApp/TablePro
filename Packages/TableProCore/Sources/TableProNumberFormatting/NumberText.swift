import Foundation

public enum NumberText {
    public static func text(for value: Double) -> String {
        withoutTrailingPointZero(value.description)
    }

    public static func text(for value: Float) -> String {
        withoutTrailingPointZero(value.description)
    }

    public static func text(for number: NSNumber) -> String {
        guard !(number is NSDecimalNumber) else { return number.stringValue }
        switch String(cString: number.objCType) {
        case "f":
            return text(for: number.floatValue)
        case "d":
            return text(for: number.doubleValue)
        default:
            return number.stringValue
        }
    }

    public static func json(from value: Any, sortedKeys: Bool = true, prettyPrinted: Bool = false) -> String? {
        guard let node = JSONNode.make(from: value) else { return nil }
        let encoder = JSONEncoder()
        var formatting: JSONEncoder.OutputFormatting = []
        if sortedKeys { formatting.insert(.sortedKeys) }
        if prettyPrinted { formatting.insert(.prettyPrinted) }
        encoder.outputFormatting = formatting
        guard let data = try? encoder.encode(node) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func withoutTrailingPointZero(_ description: String) -> String {
        description.hasSuffix(".0") ? String(description.dropLast(2)) : description
    }
}

private enum JSONNode: Encodable {
    case null
    case bool(Bool)
    case string(String)
    case decimal(Decimal)
    case double(Double)
    case float(Float)
    case integer(Int64)
    case unsignedInteger(UInt64)
    case array([JSONNode])
    case object([String: JSONNode])

    static func make(from value: Any) -> JSONNode? {
        switch value {
        case is NSNull:
            return .null
        case let string as String:
            return .string(string)
        case let number as NSNumber:
            return node(for: number)
        case let array as [Any]:
            var nodes: [JSONNode] = []
            nodes.reserveCapacity(array.count)
            for element in array {
                guard let node = make(from: element) else { return nil }
                nodes.append(node)
            }
            return .array(nodes)
        case let dictionary as [String: Any]:
            var nodes: [String: JSONNode] = [:]
            nodes.reserveCapacity(dictionary.count)
            for (key, element) in dictionary {
                guard let node = make(from: element) else { return nil }
                nodes[key] = node
            }
            return .object(nodes)
        default:
            return nil
        }
    }

    private static func node(for number: NSNumber) -> JSONNode {
        if NumberText.isBoolean(number) {
            return .bool(number.boolValue)
        }
        if number is NSDecimalNumber {
            return .decimal(number.decimalValue)
        }
        switch String(cString: number.objCType) {
        case "f":
            return .float(number.floatValue)
        case "d":
            return .double(number.doubleValue)
        case "Q":
            return .unsignedInteger(number.uint64Value)
        default:
            return .integer(number.int64Value)
        }
    }

    func encode(to encoder: any Encoder) throws {
        switch self {
        case .array(let values):
            var container = encoder.unkeyedContainer()
            for value in values {
                try container.encode(value)
            }
        case .object(let values):
            var container = encoder.container(keyedBy: JSONNodeCodingKey.self)
            for (key, value) in values {
                try container.encode(value, forKey: JSONNodeCodingKey(key))
            }
        default:
            try encodeScalar(to: encoder)
        }
    }

    private func encodeScalar(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .decimal(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .float(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        case .unsignedInteger(let value):
            try container.encode(value)
        case .array, .object:
            return
        }
    }
}

private struct JSONNodeCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init(_ stringValue: String) {
        self.stringValue = stringValue
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        return nil
    }
}
