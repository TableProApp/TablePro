import AppKit
import Foundation
import os

public struct OpenTableTabTool: MCPToolImplementation {
    public static let name = "open_table_tab"
    public static let description = String(
        localized: "Open a table tab in TablePro for the given connection."
    )
    public static let inputSchema: JsonValue = .object([
        "type": .string("object"),
        "properties": .object([
            "connection_id": .object([
                "type": .string("string"),
                "description": .string(String(localized: "UUID of the connection"))
            ]),
            "table_name": .object([
                "type": .string("string"),
                "description": .string(String(localized: "Table name to open"))
            ]),
            "database_name": .object([
                "type": .string("string"),
                "description": .string(String(localized: "Database name (uses connection's current database if omitted)"))
            ]),
            "schema_name": .object([
                "type": .string("string"),
                "description": .string(String(localized: "Schema name (for multi-schema databases)"))
            ])
        ]),
        "required": .array([.string("connection_id"), .string("table_name")])
    ])
    public static let requiredScopes: Set<MCPScope> = [.toolsRead]
    public static let annotations = MCPToolAnnotations(
        title: String(localized: "Open Table Tab"),
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false
    )

    private static let logger = Logger(subsystem: "com.TablePro", category: "MCP.Tools")

    public init() {}

    public func call(
        arguments: JsonValue,
        context: MCPRequestContext,
        services: MCPToolServices
    ) async throws -> MCPToolCallResult {
        let connectionId = try MCPArgumentDecoder.requireUuid(arguments, key: "connection_id")
        let tableName = try MCPArgumentDecoder.requireString(arguments, key: "table_name")
        let databaseName = MCPArgumentDecoder.optionalString(arguments, key: "database_name")
        let schemaName = MCPArgumentDecoder.optionalString(arguments, key: "schema_name")

        try await ensureConnectionExists(connectionId)

        Self.logger.debug("open_table_tab invoked for connection \(connectionId.uuidString, privacy: .public)")

        let windowId = await MainActor.run { () -> UUID in
            let payload = EditorTabPayload(
                connectionId: connectionId,
                tabType: .table,
                tableName: tableName,
                databaseName: databaseName,
                schemaName: schemaName,
                intent: .openContent
            )
            WindowManager.shared.openTab(payload: payload)
            NSApp.activate(ignoringOtherApps: true)
            return payload.id
        }

        let result: JsonValue = .object([
            "status": .string("opened"),
            "connection_id": .string(connectionId.uuidString),
            "table_name": .string(tableName),
            "window_id": .string(windowId.uuidString)
        ])
        return .structured(result)
    }

    private func ensureConnectionExists(_ connectionId: UUID) async throws {
        let exists = await MainActor.run {
            ConnectionStorage.shared.loadConnections().contains { $0.id == connectionId }
        }
        guard exists else {
            throw MCPProtocolError.invalidParams(detail: "Connection not found: \(connectionId.uuidString)")
        }
    }
}
