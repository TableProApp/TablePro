import Foundation

public struct MCPPrimitiveField: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case string
        case number
        case integer
        case boolean
    }

    public let name: String
    public let kind: Kind
    public let title: String?
    public let description: String?
    public let enumValues: [String]?
    public let isRequired: Bool

    public init(
        name: String,
        kind: Kind,
        title: String? = nil,
        description: String? = nil,
        enumValues: [String]? = nil,
        isRequired: Bool = true
    ) {
        self.name = name
        self.kind = kind
        self.title = title
        self.description = description
        self.enumValues = enumValues
        self.isRequired = isRequired
    }

    public var asJsonValue: JsonValue {
        var fields: [String: JsonValue] = ["type": .string(kind.rawValue)]
        if let title {
            fields["title"] = .string(title)
        }
        if let description {
            fields["description"] = .string(description)
        }
        if let enumValues {
            fields["enum"] = .array(enumValues.map { .string($0) })
        }
        return .object(fields)
    }
}

public struct MCPElicitationRequest: Sendable, Equatable {
    public static let capabilityName = "elicitation"
    public static let method = "elicitation/create"

    public let key: String
    public let message: String
    public let fields: [MCPPrimitiveField]

    public init(key: String, message: String, fields: [MCPPrimitiveField]) {
        self.key = key
        self.message = message
        self.fields = fields
    }

    public var asJsonValue: JsonValue {
        var properties: [String: JsonValue] = [:]
        var required: [JsonValue] = []
        for field in fields {
            properties[field.name] = field.asJsonValue
            if field.isRequired {
                required.append(.string(field.name))
            }
        }
        var schema: [String: JsonValue] = [
            "type": .string("object"),
            "properties": .object(properties)
        ]
        if !required.isEmpty {
            schema["required"] = .array(required.sorted { lhs, rhs in
                (lhs.stringValue ?? "") < (rhs.stringValue ?? "")
            })
        }
        return .object([
            "method": .string(Self.method),
            "params": .object([
                "mode": .string("form"),
                "message": .string(message),
                "requestedSchema": .object(schema)
            ])
        ])
    }

    public static func approval(key: String, message: String, detail: String?) -> MCPElicitationRequest {
        MCPElicitationRequest(
            key: key,
            message: message,
            fields: [
                MCPPrimitiveField(
                    name: "approved",
                    kind: .boolean,
                    title: String(localized: "Approve"),
                    description: detail
                )
            ]
        )
    }
}

public struct MCPElicitationResponse: Sendable, Equatable {
    public enum Action: String, Sendable, Equatable {
        case accept
        case decline
        case cancel
    }

    public let action: Action
    public let content: [String: JsonValue]

    public init(action: Action, content: [String: JsonValue]) {
        self.action = action
        self.content = content
    }

    public init?(json: JsonValue) {
        guard case .object(let fields) = json,
              case .string(let rawAction)? = fields["action"],
              let action = Action(rawValue: rawAction)
        else {
            return nil
        }
        self.action = action
        self.content = fields["content"]?.objectValue ?? [:]
    }

    public var isAccepted: Bool {
        action == .accept
    }

    public func bool(_ key: String) -> Bool? {
        content[key]?.boolValue
    }
}

public enum MCPInputResponses {
    public static func map(in params: JsonValue?) -> [String: JsonValue] {
        params?["inputResponses"]?.objectValue ?? [:]
    }

    public static func elicitation(named key: String, in params: JsonValue?) -> MCPElicitationResponse? {
        guard let raw = map(in: params)[key] else { return nil }
        return MCPElicitationResponse(json: raw)
    }

    public static func requestState(in params: JsonValue?) -> String? {
        guard let raw = params?["requestState"]?.stringValue, !raw.isEmpty else { return nil }
        return raw
    }
}
