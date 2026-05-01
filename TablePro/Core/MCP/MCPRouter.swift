import Foundation

final class MCPRouter: Sendable {
    enum RouteResult: Sendable {
        case json(Data, sessionId: String?)
        case sseStream(sessionId: String)
        case accepted
        case noContent
        case httpError(status: Int, message: String)
        case httpErrorWithHeaders(status: Int, message: String, extraHeaders: [(String, String)])
    }

    private let routes: [any MCPRouteHandler]

    init(routes: [any MCPRouteHandler]) {
        self.routes = routes
    }

    func handle(_ request: HTTPRequest) async -> RouteResult {
        if request.path.hasPrefix("/.well-known/") {
            return .httpError(status: 404, message: "Not found")
        }

        if request.method == .options {
            return .noContent
        }

        guard let route = match(request) else {
            return .httpError(status: 404, message: "Not found")
        }

        return await route.handle(request)
    }

    private func match(_ request: HTTPRequest) -> (any MCPRouteHandler)? {
        let normalizedPath = Self.canonicalPath(request.path)
        return routes.first { route in
            route.path == normalizedPath && route.methods.contains(request.method)
        }
    }

    private static func canonicalPath(_ path: String) -> String {
        if let queryIndex = path.firstIndex(of: "?") {
            return String(path[..<queryIndex])
        }
        return path
    }
}

extension MCPRouter {
    static func toolDefinitions() -> [MCPToolDefinition] {
        connectionTools() + schemaTools() + queryAndExportTools() + integrationTools()
    }

    private static func connectionTools() -> [MCPToolDefinition] {
        [
            MCPToolDefinition(
                name: "list_connections",
                description: "List all saved database connections with their status",
                inputSchema: .object([
                    "type": "object",
                    "properties": .object([:]),
                    "required": .array([])
                ])
            ),
            MCPToolDefinition(
                name: "connect",
                description: "Connect to a saved database",
                inputSchema: .object([
                    "type": "object",
                    "properties": .object([
                        "connection_id": .object([
                            "type": "string",
                            "description": "UUID of the saved connection"
                        ])
                    ]),
                    "required": .array([.string("connection_id")])
                ])
            ),
            MCPToolDefinition(
                name: "disconnect",
                description: "Disconnect from a database",
                inputSchema: .object([
                    "type": "object",
                    "properties": .object([
                        "connection_id": .object([
                            "type": "string",
                            "description": "UUID of the connection to disconnect"
                        ])
                    ]),
                    "required": .array([.string("connection_id")])
                ])
            ),
            MCPToolDefinition(
                name: "get_connection_status",
                description: "Get detailed status of a database connection",
                inputSchema: .object([
                    "type": "object",
                    "properties": .object([
                        "connection_id": .object([
                            "type": "string",
                            "description": "UUID of the connection"
                        ])
                    ]),
                    "required": .array([.string("connection_id")])
                ])
            ),
            MCPToolDefinition(
                name: "switch_database",
                description: "Switch the active database on a connection",
                inputSchema: .object([
                    "type": "object",
                    "properties": .object([
                        "connection_id": .object([
                            "type": "string",
                            "description": "UUID of the connection"
                        ]),
                        "database": .object([
                            "type": "string",
                            "description": "Database name to switch to"
                        ])
                    ]),
                    "required": .array([.string("connection_id"), .string("database")])
                ])
            ),
            MCPToolDefinition(
                name: "switch_schema",
                description: "Switch the active schema on a connection",
                inputSchema: .object([
                    "type": "object",
                    "properties": .object([
                        "connection_id": .object([
                            "type": "string",
                            "description": "UUID of the connection"
                        ]),
                        "schema": .object([
                            "type": "string",
                            "description": "Schema name to switch to"
                        ])
                    ]),
                    "required": .array([.string("connection_id"), .string("schema")])
                ])
            )
        ]
    }

    private static func schemaTools() -> [MCPToolDefinition] {
        [
            MCPToolDefinition(
                name: "list_databases",
                description: "List all databases on the server",
                inputSchema: .object([
                    "type": "object",
                    "properties": .object([
                        "connection_id": .object([
                            "type": "string",
                            "description": "UUID of the connection"
                        ])
                    ]),
                    "required": .array([.string("connection_id")])
                ])
            ),
            MCPToolDefinition(
                name: "list_schemas",
                description: "List schemas in a database",
                inputSchema: .object([
                    "type": "object",
                    "properties": .object([
                        "connection_id": .object([
                            "type": "string",
                            "description": "UUID of the connection"
                        ]),
                        "database": .object([
                            "type": "string",
                            "description": "Database name (uses current if omitted)"
                        ])
                    ]),
                    "required": .array([.string("connection_id")])
                ])
            ),
            MCPToolDefinition(
                name: "list_tables",
                description: "List tables and views in a database",
                inputSchema: .object([
                    "type": "object",
                    "properties": .object([
                        "connection_id": .object([
                            "type": "string",
                            "description": "UUID of the connection"
                        ]),
                        "database": .object([
                            "type": "string",
                            "description": "Database name (uses current if omitted)"
                        ]),
                        "schema": .object([
                            "type": "string",
                            "description": "Schema name (uses current if omitted)"
                        ]),
                        "include_row_counts": .object([
                            "type": "boolean",
                            "description": "Include approximate row counts (default false)"
                        ])
                    ]),
                    "required": .array([.string("connection_id")])
                ])
            ),
            MCPToolDefinition(
                name: "describe_table",
                description: "Get detailed table structure: columns, indexes, foreign keys, and DDL",
                inputSchema: .object([
                    "type": "object",
                    "properties": .object([
                        "connection_id": .object([
                            "type": "string",
                            "description": "UUID of the connection"
                        ]),
                        "table": .object([
                            "type": "string",
                            "description": "Table name"
                        ]),
                        "schema": .object([
                            "type": "string",
                            "description": "Schema name (uses current if omitted)"
                        ])
                    ]),
                    "required": .array([.string("connection_id"), .string("table")])
                ])
            ),
            MCPToolDefinition(
                name: "get_table_ddl",
                description: "Get the CREATE TABLE DDL statement for a table",
                inputSchema: .object([
                    "type": "object",
                    "properties": .object([
                        "connection_id": .object([
                            "type": "string",
                            "description": "UUID of the connection"
                        ]),
                        "table": .object([
                            "type": "string",
                            "description": "Table name"
                        ]),
                        "schema": .object([
                            "type": "string",
                            "description": "Schema name (uses current if omitted)"
                        ])
                    ]),
                    "required": .array([.string("connection_id"), .string("table")])
                ])
            )
        ]
    }

    private static func queryAndExportTools() -> [MCPToolDefinition] {
        [
            MCPToolDefinition(
                name: "execute_query",
                description: "Execute a SQL query. All queries are subject to the connection's safe mode policy. "
                    + "DROP/TRUNCATE/ALTER...DROP must use the confirm_destructive_operation tool.",
                inputSchema: .object([
                    "type": "object",
                    "properties": .object([
                        "connection_id": .object([
                            "type": "string",
                            "description": "UUID of the connection"
                        ]),
                        "query": .object([
                            "type": "string",
                            "description": "SQL or NoSQL query text"
                        ]),
                        "max_rows": .object([
                            "type": "integer",
                            "description": "Maximum rows to return (default 500, max 10000)"
                        ]),
                        "timeout_seconds": .object([
                            "type": "integer",
                            "description": "Query timeout in seconds (default 30, max 300)"
                        ]),
                        "database": .object([
                            "type": "string",
                            "description": "Switch to this database before executing"
                        ]),
                        "schema": .object([
                            "type": "string",
                            "description": "Switch to this schema before executing"
                        ])
                    ]),
                    "required": .array([.string("connection_id"), .string("query")])
                ])
            ),
            MCPToolDefinition(
                name: "export_data",
                description: "Export query results or table data to CSV, JSON, or SQL",
                inputSchema: .object([
                    "type": "object",
                    "properties": .object([
                        "connection_id": .object([
                            "type": "string",
                            "description": "UUID of the connection"
                        ]),
                        "format": .object([
                            "type": "string",
                            "description": "Export format: csv, json, or sql",
                            "enum": .array([.string("csv"), .string("json"), .string("sql")])
                        ]),
                        "query": .object([
                            "type": "string",
                            "description": "SQL query to export results from"
                        ]),
                        "tables": .object([
                            "type": "array",
                            "description": "Table names to export (alternative to query)",
                            "items": .object(["type": "string"])
                        ]),
                        "output_path": .object([
                            "type": "string",
                            "description": "File path inside the user's Downloads directory (returns inline data if omitted). Paths outside Downloads are rejected."
                        ]),
                        "max_rows": .object([
                            "type": "integer",
                            "description": "Maximum rows to export (default 50000)"
                        ])
                    ]),
                    "required": .array([.string("connection_id"), .string("format")])
                ])
            ),
            MCPToolDefinition(
                name: "confirm_destructive_operation",
                description: "Execute a destructive DDL query (DROP, TRUNCATE, ALTER...DROP) after explicit confirmation.",
                inputSchema: .object([
                    "type": "object",
                    "properties": .object([
                        "connection_id": .object([
                            "type": "string",
                            "description": "UUID of the active connection"
                        ]),
                        "query": .object([
                            "type": "string",
                            "description": "The destructive query to execute"
                        ]),
                        "confirmation_phrase": .object([
                            "type": "string",
                            "description": "Must be exactly: I understand this is irreversible"
                        ])
                    ]),
                    "required": .array([
                        .string("connection_id"),
                        .string("query"),
                        .string("confirmation_phrase")
                    ])
                ])
            )
        ]
    }

    private static func integrationTools() -> [MCPToolDefinition] {
        [
            MCPToolDefinition(
                name: "list_recent_tabs",
                description: "List currently open tabs across all TablePro windows. "
                    + "Returns connection, tab type, table name, and titles for each tab.",
                inputSchema: .object([
                    "type": "object",
                    "properties": .object([
                        "limit": .object([
                            "type": "integer",
                            "description": "Maximum number of tabs to return (default 20, max 500)"
                        ])
                    ]),
                    "required": .array([])
                ])
            ),
            MCPToolDefinition(
                name: "search_query_history",
                description: "Search saved query history. "
                    + "Returns matching entries with execution time, row count, and outcome.",
                inputSchema: .object([
                    "type": "object",
                    "properties": .object([
                        "query": .object([
                            "type": "string",
                            "description": "Search text (full-text matched against the query column)"
                        ]),
                        "connection_id": .object([
                            "type": "string",
                            "description": "Restrict to a specific connection (UUID, optional)"
                        ]),
                        "limit": .object([
                            "type": "integer",
                            "description": "Maximum number of entries to return (default 50, max 500)"
                        ]),
                        "since": .object([
                            "type": "number",
                            "description": "Earliest executed_at to include, Unix epoch seconds (inclusive, optional)"
                        ]),
                        "until": .object([
                            "type": "number",
                            "description": "Latest executed_at to include, Unix epoch seconds (inclusive, optional)"
                        ])
                    ]),
                    "required": .array([.string("query")])
                ])
            ),
            MCPToolDefinition(
                name: "open_connection_window",
                description: "Open a TablePro window for a saved connection (focuses if already open).",
                inputSchema: .object([
                    "type": "object",
                    "properties": .object([
                        "connection_id": .object([
                            "type": "string",
                            "description": "UUID of the saved connection"
                        ])
                    ]),
                    "required": .array([.string("connection_id")])
                ])
            ),
            MCPToolDefinition(
                name: "open_table_tab",
                description: "Open a table tab in TablePro for the given connection.",
                inputSchema: .object([
                    "type": "object",
                    "properties": .object([
                        "connection_id": .object([
                            "type": "string",
                            "description": "UUID of the connection"
                        ]),
                        "table_name": .object([
                            "type": "string",
                            "description": "Table name to open"
                        ]),
                        "database_name": .object([
                            "type": "string",
                            "description": "Database name (uses connection's current database if omitted)"
                        ]),
                        "schema_name": .object([
                            "type": "string",
                            "description": "Schema name (for multi-schema databases)"
                        ])
                    ]),
                    "required": .array([.string("connection_id"), .string("table_name")])
                ])
            ),
            MCPToolDefinition(
                name: "focus_query_tab",
                description: "Focus an already-open tab by id (returned from list_recent_tabs).",
                inputSchema: .object([
                    "type": "object",
                    "properties": .object([
                        "tab_id": .object([
                            "type": "string",
                            "description": "UUID of the tab to focus"
                        ])
                    ]),
                    "required": .array([.string("tab_id")])
                ])
            )
        ]
    }
}

extension MCPRouter {
    static func resourceDefinitions() -> [MCPResourceDefinition] {
        [
            MCPResourceDefinition(
                uri: "tablepro://connections",
                name: "Saved Connections",
                description: "List of all saved database connections with metadata",
                mimeType: "application/json"
            ),
            MCPResourceDefinition(
                uri: "tablepro://connections/{id}/schema",
                name: "Database Schema",
                description: "Tables, columns, indexes, and foreign keys for a connected database",
                mimeType: "application/json"
            ),
            MCPResourceDefinition(
                uri: "tablepro://connections/{id}/history",
                name: "Query History",
                description: "Recent query history for a connection (supports ?limit=, ?search=, ?date_filter=)",
                mimeType: "application/json"
            )
        ]
    }
}
