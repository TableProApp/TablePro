//
//  ChatToolContext+Helpers.swift
//  TablePro
//

import Foundation

extension ChatToolContext {
    func resolveConnectionId(_ input: JsonValue) throws -> UUID {
        if let connectionId = try? ChatToolArgumentDecoder.requireUUID(input, key: "connection_id") {
            return connectionId
        }
        if let active = connectionId {
            return active
        }
        throw ChatToolArgumentError.missingOrInvalid(
            key: "connection_id",
            expected: "UUID string (or attach a connection in the chat)"
        )
    }
}
