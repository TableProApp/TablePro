import Foundation

/// A JSON value as R2 SQL sent it, with numbers kept exact.
///
/// Numbers decode as `Decimal`, which carries 38 significant digits. Trying `Int64` first, as the
/// usual pattern does, silently truncates a fractional value whose `Double` rounding happens to be
/// integral (`12345678901234567.89` arrives as `12345678901234567`), and `Double` loses every digit
/// past the 17th.
public enum R2SQLJSONValue: Decodable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Decimal)
    case string(String)
    case array([R2SQLJSONValue])
    case object([String: R2SQLJSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Decimal.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([R2SQLJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: R2SQLJSONValue].self))
        }
    }

    public var jsonText: String {
        switch self {
        case .null:
            return "null"
        case .bool(let value):
            return value ? "true" : "false"
        case .number(let value):
            return value.description
        case .string(let value):
            return Self.quoted(value)
        case .array(let values):
            return "[" + values.map(\.jsonText).joined(separator: ",") + "]"
        case .object(let fields):
            let members = fields.keys.sorted().map { key in
                Self.quoted(key) + ":" + (fields[key] ?? .null).jsonText
            }
            return "{" + members.joined(separator: ",") + "}"
        }
    }

    private static func quoted(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value), let text = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return text
    }
}
