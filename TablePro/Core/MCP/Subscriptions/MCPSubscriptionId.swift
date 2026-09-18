import Foundation

public struct MCPSubscriptionId: Sendable, Hashable, CustomStringConvertible {
    public let requestId: JsonRpcId

    public init?(requestId: JsonRpcId) {
        if case .null = requestId { return nil }
        self.requestId = requestId
    }

    public var asJsonValue: JsonValue {
        switch requestId {
        case .string(let value):
            return .string(value)
        case .number(let value):
            guard let narrowed = Int(exactly: value) else { return .string(String(value)) }
            return .int(narrowed)
        case .null:
            return .null
        }
    }

    public var description: String {
        switch requestId {
        case .string(let value):
            return value
        case .number(let value):
            return String(value)
        case .null:
            return "null"
        }
    }
}
