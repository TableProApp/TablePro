import Foundation

public enum JSONValue: Sendable {
    case object([(key: String, value: JSONValue)])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public subscript(key: String) -> JSONValue? {
        guard case .object(let members) = self else { return nil }
        return members.first { $0.key == key }?.value
    }

    public var stringValue: String? {
        guard case .string(let string) = self else { return nil }
        return string
    }

    public var arrayValue: [JSONValue]? {
        guard case .array(let items) = self else { return nil }
        return items
    }

    public var objectMembers: [(key: String, value: JSONValue)]? {
        guard case .object(let members) = self else { return nil }
        return members
    }

    public var compactText: String {
        JSONTextStyle.compact.render(self, indent: "")
    }

    public func prettyText(indentUnit: String = "  ") -> String {
        JSONTextStyle(indentUnit: indentUnit, newline: "\n", multiline: true, spaced: true).render(self, indent: "")
    }

    static func nested(_ path: [String], leaf: JSONValue) -> JSONValue {
        path.reversed().reduce(leaf) { inner, key in .object([(key: key, value: inner)]) }
    }

    // The overlay wins member by member and an object in both merges again, so what the overlay never names stays.
    func merging(_ overlay: JSONValue) -> JSONValue {
        guard case .object(var members) = self, case .object(let additions) = overlay else { return overlay }
        for addition in additions {
            if let position = members.firstIndex(where: { $0.key == addition.key }) {
                members[position].value = members[position].value.merging(addition.value)
            } else {
                members.append(addition)
            }
        }
        return .object(members)
    }

    var foundationObject: Any {
        switch self {
        case .object(let members):
            var dictionary: [String: Any] = [:]
            for member in members where dictionary[member.key] == nil {
                dictionary[member.key] = member.value.foundationObject
            }
            return dictionary
        case .array(let items): return items.map(\.foundationObject)
        case .string(let string): return string
        case .number(let number): return NSNumber(value: number)
        case .bool(let bool): return NSNumber(value: bool)
        case .null: return NSNull()
        }
    }
}

extension JSONValue: Equatable {
    // Object members compare as a set, since JSON gives key order no meaning.
    public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case let (.object(left), .object(right)):
            guard left.count == right.count else { return false }
            return left.allSatisfy { member in
                right.contains { $0.key == member.key && $0.value == member.value }
            }
        case let (.array(left), .array(right)):
            return left == right
        case let (.string(left), .string(right)):
            return left == right
        case let (.number(left), .number(right)):
            return left == right
        case let (.bool(left), .bool(right)):
            return left == right
        case (.null, .null):
            return true
        default:
            return false
        }
    }
}

extension JSONValue: Decodable {
    private struct AnyKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil

        init(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            nil
        }
    }

    // JSONDecoder hands keys back unordered; MCPClientCatalog.decode(_:) parses the bytes itself to keep them.
    public init(from decoder: any Decoder) throws {
        if let container = try? decoder.container(keyedBy: AnyKey.self) {
            self = .object(try container.allKeys.map { key in
                (key: key.stringValue, value: try container.decode(JSONValue.self, forKey: key))
            })
            return
        }
        if var container = try? decoder.unkeyedContainer() {
            var items: [JSONValue] = []
            while !container.isAtEnd {
                items.append(try container.decode(JSONValue.self))
            }
            self = .array(items)
            return
        }
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else {
            self = .string(try container.decode(String.self))
        }
    }
}

struct JSONTextStyle {
    var indentUnit: String
    var newline: String
    var multiline: Bool
    var spaced: Bool

    static let compact = JSONTextStyle(indentUnit: "", newline: "", multiline: false, spaced: false)

    func render(_ value: JSONValue, indent: String) -> String {
        let inner = multiline ? indent + indentUnit : indent
        switch value {
        case .object(let members):
            guard !members.isEmpty else { return "{}" }
            let colon = spaced ? ": " : ":"
            return wrap("{", "}", indent: indent, members.map { Self.quoted($0.key) + colon + render($0.value, indent: inner) })
        case .array(let items):
            guard !items.isEmpty else { return "[]" }
            return wrap("[", "]", indent: indent, items.map { render($0, indent: inner) })
        case .string(let string):
            return Self.quoted(string)
        case .number(let number):
            return Self.numberText(number)
        case .bool(let bool):
            return bool ? "true" : "false"
        case .null:
            return "null"
        }
    }

    private func wrap(_ open: String, _ close: String, indent: String, _ items: [String]) -> String {
        guard multiline else {
            return open + items.joined(separator: spaced ? ", " : ",") + close
        }
        let inner = indent + indentUnit
        return open + newline + items.map { inner + $0 }.joined(separator: "," + newline) + newline + indent + close
    }

    static func quoted(_ string: String) -> String {
        var result = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case "\u{08}": result += "\\b"
            case "\u{0C}": result += "\\f"
            default:
                if scalar.value < 0x20 {
                    result += String(format: "\\u%04x", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "\""
    }

    static func numberText(_ number: Double) -> String {
        guard number.isFinite else { return "null" }
        if number == number.rounded(), abs(number) < 1e15 {
            return String(Int64(number))
        }
        return "\(number)"
    }
}
