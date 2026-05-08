//
//  GetConnectionStatusChatTool.swift
//  TablePro
//

import Foundation

struct GetConnectionStatusChatTool: ChatTool {
    let name = "get_connection_status"
    let description = String(localized: "Get detailed status for a specific database connection.")
    let inputSchema: JsonValue = .object([
        "type": .string("object"),
        "properties": .object([
            "connection_id": .object([
                "type": .string("string"),
                "description": .string("UUID of the connection")
            ])
        ]),
        "required": .array([.string("connection_id")])
    ])

    func execute(input: JsonValue, context: ChatToolContext) async throws -> ChatToolResult {
        let connectionId = try resolveConnectionId(input: input, context: context)
        let payload = try await context.bridge.getConnectionStatus(connectionId: connectionId)
        return ChatToolResult(content: payload.jsonString(prettyPrinted: true))
    }
}

func resolveConnectionId(input: JsonValue, context: ChatToolContext) throws -> UUID {
    if let connectionId = try? ChatToolArgumentDecoder.requireUUID(input, key: "connection_id") {
        return connectionId
    }
    if let active = context.connectionId {
        return active
    }
    throw ChatToolArgumentError.missingOrInvalid(key: "connection_id", expected: "UUID string (or attach a connection in the chat)")
}
