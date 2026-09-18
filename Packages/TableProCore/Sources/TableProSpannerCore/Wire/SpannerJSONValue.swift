import Foundation

public enum SpannerJSONValue: Codable, Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case list([SpannerJSONValue])
    case object([String: SpannerJSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let text = try? container.decode(String.self) {
            self = .string(text)
        } else if let flag = try? container.decode(Bool.self) {
            self = .bool(flag)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let list = try? container.decode([SpannerJSONValue].self) {
            self = .list(list)
        } else {
            self = .object(try container.decode([String: SpannerJSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let flag):
            try container.encode(flag)
        case .number(let number):
            try container.encode(number)
        case .string(let text):
            try container.encode(text)
        case .list(let list):
            try container.encode(list)
        case .object(let object):
            try container.encode(object)
        }
    }
}
