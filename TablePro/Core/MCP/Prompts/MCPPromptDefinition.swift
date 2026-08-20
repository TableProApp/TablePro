import Foundation

public enum MCPPromptRole: String, Sendable, Equatable {
    case user
    case assistant
}

public struct MCPPromptMessage: Sendable, Equatable {
    public let role: MCPPromptRole
    public let text: String

    public init(role: MCPPromptRole, text: String) {
        self.role = role
        self.text = text
    }

    public static func user(_ text: String) -> MCPPromptMessage {
        MCPPromptMessage(role: .user, text: text)
    }

    public static func assistant(_ text: String) -> MCPPromptMessage {
        MCPPromptMessage(role: .assistant, text: text)
    }

    public var asJsonValue: JsonValue {
        .object([
            "role": .string(role.rawValue),
            "content": .object([
                "type": .string("text"),
                "text": .string(text)
            ])
        ])
    }
}

public struct MCPPromptRendering: Sendable, Equatable {
    public let description: String
    public let messages: [MCPPromptMessage]

    public init(description: String, messages: [MCPPromptMessage]) {
        self.description = description
        self.messages = messages
    }

    public var asPayload: [String: JsonValue] {
        [
            "description": .string(description),
            "messages": .array(messages.map(\.asJsonValue))
        ]
    }
}

public enum MCPPromptArgumentCompletion: Sendable, Equatable {
    case none
    case values([String])
    case connection
    case connectionId
    case database
    case schema
    case table
}

public struct MCPPromptArgument: Sendable, Equatable {
    public let name: String
    public let title: String
    public let description: String
    public let isRequired: Bool
    public let completion: MCPPromptArgumentCompletion

    public init(
        name: String,
        title: String,
        description: String,
        isRequired: Bool = false,
        completion: MCPPromptArgumentCompletion = .none
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.isRequired = isRequired
        self.completion = completion
    }

    public var asJsonValue: JsonValue {
        .object([
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "required": .bool(isRequired)
        ])
    }
}

public struct MCPPromptDefinition: Sendable {
    public typealias Renderer = @Sendable (MCPPromptRenderContext) async throws -> MCPPromptRendering

    public let name: String
    public let title: String
    public let description: String
    public let arguments: [MCPPromptArgument]
    public let render: Renderer

    public init(
        name: String,
        title: String,
        description: String,
        arguments: [MCPPromptArgument],
        render: @escaping Renderer
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.arguments = arguments
        self.render = render
    }

    public func argument(named name: String) -> MCPPromptArgument? {
        arguments.first { $0.name == name }
    }

    public var asJsonValue: JsonValue {
        var fields: [String: JsonValue] = [
            "name": .string(name),
            "title": .string(title),
            "description": .string(description)
        ]
        if !arguments.isEmpty {
            fields["arguments"] = .array(arguments.map(\.asJsonValue))
        }
        return .object(fields)
    }
}

public struct MCPPromptRenderContext: Sendable {
    public let principal: MCPPrincipal
    public let arguments: [String: String]
    let schema: MCPPromptSchemaReader
}

public extension MCPPromptRenderContext {
    func value(_ name: String) -> String? {
        guard let raw = arguments[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return raw
    }

    func requiredValue(_ name: String) throws -> String {
        guard let value = value(name) else {
            throw MCPProtocolError.invalidParams(detail: "Missing required argument: \(name)")
        }
        return value
    }

    func choice(_ name: String, allowed: [String], default fallback: String) throws -> String {
        guard let raw = value(name) else { return fallback }
        guard let match = allowed.first(where: { $0.caseInsensitiveCompare(raw) == .orderedSame }) else {
            throw MCPProtocolError.invalidParams(
                detail: "Invalid value for \(name): \(raw). Allowed values: \(allowed.joined(separator: ", "))"
            )
        }
        return match
    }

    func integer(_ name: String, default fallback: Int, clamp: ClosedRange<Int>) throws -> Int {
        guard let raw = value(name) else { return fallback }
        guard let parsed = Int(raw) else {
            throw MCPProtocolError.invalidParams(detail: "Invalid integer for \(name): \(raw)")
        }
        return min(max(parsed, clamp.lowerBound), clamp.upperBound)
    }

    func list(_ name: String) -> [String] {
        guard let raw = value(name) else { return [] }
        return raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

extension MCPPromptRenderContext {
    func resolveTarget() async throws -> MCPPromptTarget {
        try await schema.target(
            reference: requiredValue(MCPPromptArgument.connectionArgumentName),
            database: value(MCPPromptArgument.databaseArgumentName),
            schema: value(MCPPromptArgument.schemaArgumentName),
            principal: principal
        )
    }
}
