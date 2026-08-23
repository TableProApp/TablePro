import Foundation

public protocol MCPToolImplementation: Sendable {
    static var name: String { get }
    static var title: String? { get }
    static var description: String { get }
    static var inputSchema: JsonValue { get }
    static var outputSchema: JsonValue? { get }
    static var icons: [MCPToolIcon] { get }
    static var annotations: MCPToolAnnotations { get }
    static var requiredScopes: Set<MCPScope> { get }

    func perform(
        arguments: JsonValue,
        context: MCPRequestContext,
        services: MCPToolServices
    ) async throws -> MCPToolCallResult

    func call(
        arguments: JsonValue,
        context: MCPRequestContext,
        services: MCPToolServices
    ) async throws -> MCPToolCallResult
}

public extension MCPToolImplementation {
    static var title: String? { nil }
    static var outputSchema: JsonValue? { nil }
    static var icons: [MCPToolIcon] { [] }
    static var annotations: MCPToolAnnotations { MCPToolAnnotations() }

    var name: String { Self.name }
    var description: String { Self.description }
    var inputSchema: JsonValue { Self.inputSchema }
    var outputSchema: JsonValue? { Self.outputSchema }
    var requiredScopes: Set<MCPScope> { Self.requiredScopes }

    func call(
        arguments: JsonValue,
        context: MCPRequestContext,
        services: MCPToolServices
    ) async throws -> MCPToolCallResult {
        do {
            return try await perform(arguments: arguments, context: context, services: services)
        } catch let signal as MCPInputRequired {
            throw signal
        } catch let error as MCPProtocolError {
            throw error
        } catch let error as MCPToolExecutionError {
            return error.asToolResult
        } catch let error as MCPDataLayerError {
            return MCPToolExecutionError.from(error).asToolResult
        } catch is CancellationError {
            throw MCPProtocolError.requestCancelled()
        } catch {
            return MCPToolExecutionError(
                code: .internalFailure,
                message: MCPErrorRedactor.message(for: error)
            ).asToolResult
        }
    }
}

public struct MCPToolIcon: Sendable, Equatable {
    public enum Theme: String, Sendable, Equatable {
        case light
        case dark
    }

    public let source: String
    public let mimeType: String?
    public let sizes: [String]
    public let theme: Theme?

    public init(source: String, mimeType: String? = nil, sizes: [String] = [], theme: Theme? = nil) {
        self.source = source
        self.mimeType = mimeType
        self.sizes = sizes
        self.theme = theme
    }

    public var asJsonValue: JsonValue {
        var fields: [String: JsonValue] = ["src": .string(source)]
        if let mimeType {
            fields["mimeType"] = .string(mimeType)
        }
        if !sizes.isEmpty {
            fields["sizes"] = .array(sizes.map { .string($0) })
        }
        if let theme {
            fields["theme"] = .string(theme.rawValue)
        }
        return .object(fields)
    }
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
        MCPToolCallResult(content: [.text(encodeJsonString(value))], isError: isError)
    }

    public static func structured(_ value: JsonValue) -> MCPToolCallResult {
        MCPToolCallResult(
            content: [.text(encodeJsonString(value))],
            structuredContent: value,
            isError: false
        )
    }

    public static func structured(_ value: JsonValue, attaching extra: [MCPToolContentItem]) -> MCPToolCallResult {
        MCPToolCallResult(
            content: [.text(encodeJsonString(value))] + extra,
            structuredContent: value,
            isError: false
        )
    }

    static func encodeJsonString(_ value: JsonValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value),
              let string = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return string
    }
}

public enum MCPToolContentItem: Sendable, Equatable {
    case text(String)
    case image(base64Data: String, mimeType: String)
    case audio(base64Data: String, mimeType: String)
    case resourceLink(uri: String, name: String, description: String?, mimeType: String?)
    case embeddedText(uri: String, text: String, mimeType: String?)

    public var asJsonValue: JsonValue {
        switch self {
        case .text(let value):
            return .object(["type": .string("text"), "text": .string(value)])
        case .image(let data, let mimeType):
            return .object([
                "type": .string("image"),
                "data": .string(data),
                "mimeType": .string(mimeType)
            ])
        case .audio(let data, let mimeType):
            return .object([
                "type": .string("audio"),
                "data": .string(data),
                "mimeType": .string(mimeType)
            ])
        case .resourceLink(let uri, let name, let description, let mimeType):
            var fields: [String: JsonValue] = [
                "type": .string("resource_link"),
                "uri": .string(uri),
                "name": .string(name)
            ]
            if let description {
                fields["description"] = .string(description)
            }
            if let mimeType {
                fields["mimeType"] = .string(mimeType)
            }
            return .object(fields)
        case .embeddedText(let uri, let text, let mimeType):
            var resource: [String: JsonValue] = ["uri": .string(uri), "text": .string(text)]
            if let mimeType {
                resource["mimeType"] = .string(mimeType)
            }
            return .object(["type": .string("resource"), "resource": .object(resource)])
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
        fields["isError"] = .bool(isError)
        return .object(fields)
    }
}
