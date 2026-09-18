import Foundation

public enum MCPPromptCatalog {
    public static let all: [MCPPromptDefinition] = schemaPrompts + queryPrompts + operationsPrompts

    public static func prompt(named name: String) -> MCPPromptDefinition? {
        all.first { $0.name == name }
    }

    public static func argument(promptName: String, argumentName: String) -> MCPPromptArgument? {
        prompt(named: promptName)?.argument(named: argumentName)
    }
}

public extension MCPPromptArgument {
    static let connectionArgumentName = "connection"
    static let databaseArgumentName = "database"
    static let schemaArgumentName = "schema"
    static let tableArgumentName = "table"

    static var connection: MCPPromptArgument {
        MCPPromptArgument(
            name: connectionArgumentName,
            title: String(localized: "Connection"),
            description: String(localized: "Name or UUID of a TablePro connection"),
            isRequired: true,
            completion: .connection
        )
    }

    static var database: MCPPromptArgument {
        MCPPromptArgument(
            name: databaseArgumentName,
            title: String(localized: "Database"),
            description: String(localized: "Database to read. Uses the connection's current database when omitted"),
            completion: .database
        )
    }

    static var schema: MCPPromptArgument {
        MCPPromptArgument(
            name: schemaArgumentName,
            title: String(localized: "Schema"),
            description: String(localized: "Schema to read. Uses the connection's current schema when omitted"),
            completion: .schema
        )
    }

    static func table(description: String, isRequired: Bool = true) -> MCPPromptArgument {
        MCPPromptArgument(
            name: tableArgumentName,
            title: String(localized: "Table"),
            description: description,
            isRequired: isRequired,
            completion: .table
        )
    }
}
