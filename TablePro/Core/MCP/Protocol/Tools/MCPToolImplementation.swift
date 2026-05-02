import Foundation

public protocol MCPToolImplementation: Sendable {
    static var name: String { get }
    static var description: String { get }
    static var inputSchema: JsonValue { get }
    static var requiredScopes: Set<MCPScope> { get }
    func call(arguments: JsonValue, context: MCPRequestContext, services: MCPToolServices) async throws -> MCPToolCallResult
}

public extension MCPToolImplementation {
    var name: String { Self.name }
    var description: String { Self.description }
    var inputSchema: JsonValue { Self.inputSchema }
    var requiredScopes: Set<MCPScope> { Self.requiredScopes }
}

public struct MCPToolCallResult: Sendable {
    public let content: [MCPToolContentItem]
    public let isError: Bool

    public init(content: [MCPToolContentItem], isError: Bool = false) {
        self.content = content
        self.isError = isError
    }

    public static func text(_ value: String, isError: Bool = false) -> MCPToolCallResult {
        MCPToolCallResult(content: [.text(value)], isError: isError)
    }

    public static func json(_ value: JsonValue, isError: Bool = false) -> MCPToolCallResult {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return MCPToolCallResult(content: [.text(encoded)], isError: isError)
    }
}

public enum MCPToolContentItem: Sendable, Equatable {
    case text(String)

    var asJsonValue: JsonValue {
        switch self {
        case .text(let value):
            return .object([
                "type": .string("text"),
                "text": .string(value)
            ])
        }
    }
}

public extension MCPToolCallResult {
    func asJsonValue() -> JsonValue {
        var fields: [String: JsonValue] = [
            "content": .array(content.map { $0.asJsonValue })
        ]
        if isError {
            fields["isError"] = .bool(true)
        }
        return .object(fields)
    }
}
