//
//  ChatToolContext+Helpers.swift
//  TablePro
//

import Foundation

extension ChatToolContext {
    /// The connection a tool call acts on, pinned to the session's own.
    ///
    /// `connection_id` is a model-fillable input on eight of the nine chat tools, and this used to
    /// prefer the model's value over the session's. `list_connections` is read-only, so it is
    /// auto-approved and can enumerate every connection's id first: a session could be told to read
    /// or write a connection the user never opened, at that connection's Safe Mode level rather
    /// than at the one on screen.
    ///
    /// A session with no connection refuses rather than falling back to the model's value. No
    /// connection means no query, not an unchecked query on whichever one was named.
    func resolveConnectionId(_ input: JsonValue) throws -> UUID {
        if let requested = try? ChatToolArgumentDecoder.requireUUID(input, key: "connection_id") {
            guard requested == connectionId else {
                throw ChatToolArgumentError.connectionOutsideSession(
                    requested: requested,
                    session: connectionId
                )
            }
            return requested
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
