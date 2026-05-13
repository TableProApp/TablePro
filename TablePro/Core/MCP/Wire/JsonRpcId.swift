import Foundation

public enum JsonRpcId: Codable, Equatable, Hashable, Sendable {
    case string(String)
    case number(Int64)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
            return
        }

        if let intValue = try? container.decode(Int64.self) {
            self = .number(intValue)
            return
        }

        if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
            return
        }

        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "JsonRpcId must be a string, integer, or null"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}
