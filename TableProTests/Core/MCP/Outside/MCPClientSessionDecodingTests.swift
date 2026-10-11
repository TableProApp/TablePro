//
//  MCPClientSessionDecodingTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct MCPClientSessionDecodingTests {
    @Test("Text parts are joined in order")
    func textPartsAreJoined() {
        let result = JsonValue.object([
            "content": .array([
                .object(["type": .string("text"), "text": .string("first")]),
                .object(["type": .string("text"), "text": .string("second")])
            ])
        ])

        #expect(MCPClientSession.flattenContent(result) == "first\nsecond")
    }

    /// An image or an embedded resource from an outside server would be a second thing to trust, and
    /// the result the model reads is text either way.
    @Test("Non-text parts are dropped")
    func nonTextPartsAreDropped() {
        let result = JsonValue.object([
            "content": .array([
                .object(["type": .string("image"), "data": .string("AAAA")]),
                .object(["type": .string("text"), "text": .string("kept")])
            ])
        ])

        #expect(MCPClientSession.flattenContent(result) == "kept")
    }

    @Test("A structured-only result falls back to its JSON")
    func structuredOnlyResultFallsBack() {
        let result = JsonValue.object([
            "structuredContent": .object(["status": .string("green")])
        ])

        #expect(MCPClientSession.flattenContent(result).contains("green"))
    }

    @Test("An answer that is not an object reads as empty")
    func nonObjectResultIsEmpty() {
        #expect(MCPClientSession.flattenContent(.string("nope")).isEmpty)
        #expect(MCPClientSession.flattenContent(.object(["content": .array([])])).isEmpty)
    }

    /// `initialize` is advertised at the newest version that still has one. Naming the era that
    /// removed the handshake on a request the specification no longer has is telling the server two
    /// contradictory things.
    @Test("The handshake advertises a version that has a handshake")
    func handshakeVersionIsALegacyOne() {
        #expect(MCPProtocolVersion.legacy.contains(MCPClientSession.legacyHandshakeVersion))
        #expect(MCPClientSession.legacyHandshakeVersion.isSupported)
        #expect(MCPProtocolVersion.latest.era == .modern)
    }

    @Test("Every error carries a sentence a reader can act on")
    func everyErrorHasAMessage() {
        let errors: [MCPClientError] = [
            .notConfigured,
            .timedOut,
            .transport("the host went away"),
            .server(code: -32_601, message: "no such method"),
            .malformedResponse,
            .sessionExpired
        ]

        for error in errors {
            #expect(!error.localizedMessage.isEmpty)
        }
        #expect(MCPClientError.transport("the host went away").localizedMessage == "the host went away")
        #expect(MCPClientError.server(code: 1, message: "boom").localizedMessage == "boom")
    }
}
