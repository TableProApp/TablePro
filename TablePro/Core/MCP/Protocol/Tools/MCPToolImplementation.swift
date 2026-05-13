import Foundation

public protocol MCPToolImplementation: Sendable {
    static var name: String { get }
    static var title: String? { get }
    static var description: String { get }
    static var inputSchema: JsonValue { get }
    static var annotations: MCPToolAnnotations { get }
    static var requiredScopes: Set<MCPScope> { get }
    func call(arguments: JsonValue, context: MCPRequestContext, services: MCPToolServices) async throws -> MCPToolCallResult
}

public extension MCPToolImplementation {
    static var title: String? { nil }
    static var annotations: MCPToolAnnotations { MCPToolAnnotations() }

    var name: String { Self.name }
    var description: String { Self.description }
    var inputSchema: JsonValue { Self.inputSchema }
    var requiredScopes: Set<MCPScope> { Self.requiredScopes }
}

public struct MCPToolAnnotations: Sendable, Equatable {
    public let title: String?
    public let readOnlyHint: Bool?
    public let destructiveHint: Bool?
    public let idempotentHint: Bool?
    public let openWorldHint: Bool?

    public init(
        title: String? = nil,
        readOnlyHint: Bool? = nil,
        destructiveHint: Bool? = nil,
        idempotentHint: Bool? = nil,
        openWorldHint: Bool? = nil
    ) {
        self.title = title
        self.readOnlyHint = readOnlyHint
        self.destructiveHint = destructiveHint
        self.idempotentHint = idempotentHint
        self.openWorldHint = openWorldHint
    }

    public var asJsonValue: JsonValue? {
        var fields: [String: JsonValue] = [:]
        if let title {
            fields["title"] = .string(title)
        }
        if let readOnlyHint {
            fields["readOnlyHint"] = .bool(readOnlyHint)
        }
        if let destructiveHint {
            fields["destructiveHint"] = .bool(destructiveHint)
        }
        if let idempotentHint {
            fields["idempotentHint"] = .bool(idempotentHint)
        }
        if let openWorldHint {
            fields["openWorldHint"] = .bool(openWorldHint)
        }
        guard !fields.isEmpty else { return nil }
        return .object(fields)
    }
}

public struct MCPToolCallResult: Sendable {
    public let content: [MCPToolContentItem]
    public let structuredContent: JsonValue?
    public let isError: Bool

    public init(
        content: [MCPToolContentItem],
        structuredContent: JsonValue? = nil,
        isError: Bool = false
    ) {
        self.content = content
        self.structuredContent = structuredContent
        self.isError = isError
    }

    public static func text(_ value: String, isError: Bool = false) -> MCPToolCallResult {
        MCPToolCallResult(content: [.text(value)], isError: isError)
    }

    public static func json(_ value: JsonValue, isError: Bool = false) -> MCPToolCallResult {
        let encoded = encodeJsonString(value)
        return MCPToolCallResult(content: [.text(encoded)], isError: isError)
    }

    public static func structured(_ value: JsonValue, isError: Bool = false) -> MCPToolCallResult {
        let encoded = encodeJsonString(value)
        return MCPToolCallResult(
            content: [.text(encoded)],
            structuredContent: value,
            isError: isError
        )
    }

    private static func encodeJsonString(_ value: JsonValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
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
        if let structuredContent {
            fields["structuredContent"] = structuredContent
        }
        if isError {
            fields["isError"] = .bool(true)
        }
        return .object(fields)
    }
}
