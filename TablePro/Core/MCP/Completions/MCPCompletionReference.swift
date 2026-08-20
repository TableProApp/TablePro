import Foundation

public enum MCPCompletionReference: Sendable, Equatable {
    case prompt(name: String)
    case resourceTemplate(uri: String)
}

public extension MCPCompletionReference {
    static let promptType = "ref/prompt"
    static let resourceType = "ref/resource"

    static let resourceTemplates = [
        ResourcesUriRoute.Template.connections,
        ResourcesUriRoute.Template.schema,
        ResourcesUriRoute.Template.history,
        ResourcesUriRoute.Template.databases,
        ResourcesUriRoute.Template.schemas,
        ResourcesUriRoute.Template.tables,
        ResourcesUriRoute.Template.table,
        ResourcesUriRoute.Template.tableDefinition
    ]

    static func decode(_ value: JsonValue?) throws -> MCPCompletionReference {
        guard let value, let type = value["type"]?.stringValue else {
            throw MCPProtocolError.invalidParams(detail: "Missing required parameter: ref.type")
        }
        switch type {
        case promptType:
            guard let name = value["name"]?.stringValue, !name.isEmpty else {
                throw MCPProtocolError.invalidParams(detail: "Missing required parameter: ref.name")
            }
            return .prompt(name: name)
        case resourceType:
            guard let uri = value["uri"]?.stringValue, !uri.isEmpty else {
                throw MCPProtocolError.invalidParams(detail: "Missing required parameter: ref.uri")
            }
            return .resourceTemplate(uri: uri)
        default:
            throw MCPProtocolError.invalidParams(detail: "Unsupported completion reference type: \(type)")
        }
    }

    func validate() throws {
        switch self {
        case .prompt(let name):
            guard MCPPromptCatalog.prompt(named: name) != nil else {
                throw MCPProtocolError.invalidParams(detail: "Unknown prompt: \(name)")
            }
        case .resourceTemplate(let uri):
            guard Self.resourceTemplates.contains(uri) || (try? ResourcesUriRoute.parse(uri: uri)) != nil else {
                throw MCPProtocolError.invalidParams(detail: "Unknown resource template: \(uri)")
            }
        }
    }

    var describedReference: String {
        switch self {
        case .prompt(let name):
            "\(Self.promptType):\(name)"
        case .resourceTemplate(let uri):
            "\(Self.resourceType):\(uri)"
        }
    }
}

public enum MCPCompletionTarget: Sendable, Equatable {
    case values([String])
    case connection
    case connectionId
    case database
    case schema
    case table
}

public extension MCPCompletionTarget {
    var hasDeclaredOrder: Bool {
        if case .values = self { return true }
        return false
    }

    static func resolve(reference: MCPCompletionReference, argumentName: String) -> MCPCompletionTarget? {
        switch reference {
        case .prompt(let name):
            return promptTarget(promptName: name, argumentName: argumentName)
        case .resourceTemplate:
            return templateTarget(variableName: argumentName)
        }
    }

    private static func promptTarget(promptName: String, argumentName: String) -> MCPCompletionTarget? {
        guard let argument = MCPPromptCatalog.argument(promptName: promptName, argumentName: argumentName) else {
            return nil
        }
        switch argument.completion {
        case .none:
            return nil
        case .values(let values):
            return .values(values)
        case .connection:
            return .connection
        case .connectionId:
            return .connectionId
        case .database:
            return .database
        case .schema:
            return .schema
        case .table:
            return .table
        }
    }

    private static func templateTarget(variableName: String) -> MCPCompletionTarget? {
        switch variableName {
        case "connection_id":
            return .connectionId
        case "database":
            return .database
        case "schema":
            return .schema
        case "table":
            return .table
        case "date_filter":
            return .values(["today", "thisWeek", "thisMonth"])
        case "row_counts":
            return .values(["true", "false"])
        default:
            return nil
        }
    }
}
