import Foundation

public struct MCPServerCapabilities: Sendable, Equatable {
    public let tools: ListChanged?
    public let resources: Resources?
    public let prompts: ListChanged?
    public let completions: Bool
    public let extensions: [String: JsonValue]

    public struct ListChanged: Sendable, Equatable {
        public let listChanged: Bool

        public init(listChanged: Bool) {
            self.listChanged = listChanged
        }

        public var asJsonValue: JsonValue {
            .object(["listChanged": .bool(listChanged)])
        }
    }

    public struct Resources: Sendable, Equatable {
        public let subscribe: Bool
        public let listChanged: Bool

        public init(subscribe: Bool, listChanged: Bool) {
            self.subscribe = subscribe
            self.listChanged = listChanged
        }

        public var asJsonValue: JsonValue {
            .object([
                "subscribe": .bool(subscribe),
                "listChanged": .bool(listChanged)
            ])
        }
    }

    public init(
        tools: ListChanged?,
        resources: Resources?,
        prompts: ListChanged?,
        completions: Bool,
        extensions: [String: JsonValue] = [:]
    ) {
        self.tools = tools
        self.resources = resources
        self.prompts = prompts
        self.completions = completions
        self.extensions = extensions
    }

    public func asJsonValue(era: MCPEra) -> JsonValue {
        var fields: [String: JsonValue] = [:]
        if let tools {
            fields["tools"] = tools.asJsonValue
        }
        if let resources {
            fields["resources"] = era == .modern
                ? resources.asJsonValue
                : .object(["subscribe": .bool(false), "listChanged": .bool(resources.listChanged)])
        }
        if let prompts {
            fields["prompts"] = prompts.asJsonValue
        }
        if completions {
            fields["completions"] = .object([:])
        }
        if era == .modern {
            fields["extensions"] = .object(extensions)
        }
        return .object(fields)
    }
}
