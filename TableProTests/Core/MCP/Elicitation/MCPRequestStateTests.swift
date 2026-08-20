//
//  MCPRequestStateTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("MCPRequestState")
struct MCPRequestStateTests {
    private func principal(fingerprint: String = "fp-1", tokenId: UUID? = nil) -> MCPPrincipal {
        MCPPrincipal(
            tokenFingerprint: fingerprint,
            tokenId: tokenId,
            scopes: [.toolsRead],
            metadata: MCPPrincipalMetadata(label: "test", issuedAt: Date(), expiresAt: nil)
        )
    }

    @Test("A sealed payload round trips")
    func roundTrip() throws {
        let now = Date()
        let token = try MCPRequestState.seal(
            .object(["consent": .string("approve")]),
            principal: principal(),
            method: "tools/call",
            paramsDigest: "digest",
            expiresAt: now.addingTimeInterval(60)
        )
        let opened = try MCPRequestState.open(
            token,
            principal: principal(),
            method: "tools/call",
            paramsDigest: "digest",
            now: now
        )
        #expect(opened["consent"]?.stringValue == "approve")
    }

    @Test("A tampered payload is rejected")
    func tamperedPayload() throws {
        let now = Date()
        let token = try MCPRequestState.seal(
            .object(["consent": .string("approve")]),
            principal: principal(),
            method: "tools/call",
            paramsDigest: "digest",
            expiresAt: now.addingTimeInterval(60)
        )
        let parts = token.split(separator: ".")
        let forged = "eyJ2ZXJzaW9uIjoxfQ." + String(parts[1])
        #expect(throws: MCPRequestStateError.signatureMismatch) {
            _ = try MCPRequestState.open(
                forged,
                principal: principal(),
                method: "tools/call",
                paramsDigest: "digest",
                now: now
            )
        }
    }

    @Test("State is bound to the principal, the method, the params, and the clock")
    func bindings() throws {
        let now = Date()
        let token = try MCPRequestState.seal(
            .object([:]),
            principal: principal(),
            method: "tools/call",
            paramsDigest: "digest",
            expiresAt: now.addingTimeInterval(60)
        )
        #expect(throws: MCPRequestStateError.principalMismatch) {
            _ = try MCPRequestState.open(
                token,
                principal: principal(fingerprint: "fp-2"),
                method: "tools/call",
                paramsDigest: "digest",
                now: now
            )
        }
        #expect(throws: MCPRequestStateError.requestMismatch) {
            _ = try MCPRequestState.open(
                token,
                principal: principal(),
                method: "resources/read",
                paramsDigest: "digest",
                now: now
            )
        }
        #expect(throws: MCPRequestStateError.requestMismatch) {
            _ = try MCPRequestState.open(
                token,
                principal: principal(),
                method: "tools/call",
                paramsDigest: "other",
                now: now
            )
        }
        #expect(throws: MCPRequestStateError.expired) {
            _ = try MCPRequestState.open(
                token,
                principal: principal(),
                method: "tools/call",
                paramsDigest: "digest",
                now: now.addingTimeInterval(120)
            )
        }
    }

    @Test("Malformed input is rejected rather than trusted")
    func malformed() {
        #expect(throws: MCPRequestStateError.malformed) {
            _ = try MCPRequestState.open(
                "not-a-token",
                principal: principal(),
                method: "tools/call",
                paramsDigest: "digest",
                now: Date()
            )
        }
    }

    @Test("The digest ignores the fields the retry adds")
    func digestIgnoresRetryFields() {
        let first = MCPRequestState.digest(ofParams: .object([
            "name": .string("execute_query"),
            "arguments": .object(["query": .string("SELECT 1")])
        ]))
        let retry = MCPRequestState.digest(ofParams: .object([
            "name": .string("execute_query"),
            "arguments": .object(["query": .string("SELECT 1")]),
            "requestState": .string("blob"),
            "inputResponses": .object(["k": .object(["action": .string("accept")])]),
            "_meta": .object(["io.modelcontextprotocol/protocolVersion": .string("2026-07-28")])
        ]))
        #expect(first == retry)

        let different = MCPRequestState.digest(ofParams: .object([
            "name": .string("execute_query"),
            "arguments": .object(["query": .string("DROP TABLE users")])
        ]))
        #expect(first != different)
    }
}

@Suite("MCPRequestState replay resistance")
struct MCPRequestStateReplayTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func principal(fingerprint: String = "fp-1", tokenId: UUID? = nil) -> MCPPrincipal {
        MCPPrincipal(
            tokenFingerprint: fingerprint,
            tokenId: tokenId,
            scopes: [.toolsRead],
            metadata: MCPPrincipalMetadata(label: "test", issuedAt: Date(), expiresAt: nil)
        )
    }

    private func seal(
        principal: MCPPrincipal,
        expiresAt: Date? = nil
    ) throws -> String {
        try MCPRequestState.seal(
            .object(["consent": .string("approve_statement")]),
            principal: principal,
            method: "tools/call",
            paramsDigest: "digest",
            expiresAt: expiresAt ?? now.addingTimeInterval(300)
        )
    }

    @Test("The state is bound to the token id, not only to the fingerprint")
    func stateIsBoundToTheTokenId() throws {
        let token = try seal(principal: principal())
        #expect(throws: MCPRequestStateError.principalMismatch) {
            _ = try MCPRequestState.open(
                token,
                principal: principal(tokenId: UUID()),
                method: "tools/call",
                paramsDigest: "digest",
                now: now
            )
        }
    }

    @Test("A state that has reached its expiry is already expired")
    func expiryIsExclusive() throws {
        let token = try seal(principal: principal(), expiresAt: now)
        #expect(throws: MCPRequestStateError.expired) {
            _ = try MCPRequestState.open(
                token,
                principal: principal(),
                method: "tools/call",
                paramsDigest: "digest",
                now: now
            )
        }
    }

    @Test("Two seals of the same payload differ, so a state cannot be guessed from a previous one")
    func sealsAreNotDeterministic() throws {
        let first = try seal(principal: principal())
        let second = try seal(principal: principal())
        #expect(first != second)
    }

    @Test("The digest covers the arguments and ignores only the retry envelope")
    func digestCoversArgumentsOnly() {
        let base = JsonValue.object([
            "name": .string("confirm_destructive_operation"),
            "arguments": .object(["query": .string("DROP TABLE users")])
        ])
        #expect(MCPRequestState.digest(ofParams: base) != "")
        #expect(
            MCPRequestState.salientParameters(base)["requestState"] == nil
        )

        let withEnvelope = JsonValue.object([
            "name": .string("confirm_destructive_operation"),
            "arguments": .object(["query": .string("DROP TABLE users")]),
            "requestState": .string("blob"),
            "inputResponses": .object([:]),
            "_meta": .object(["io.modelcontextprotocol/protocolVersion": .string("2026-07-28")])
        ])
        #expect(MCPRequestState.digest(ofParams: withEnvelope) == MCPRequestState.digest(ofParams: base))

        let renamedTool = JsonValue.object([
            "name": .string("execute_query"),
            "arguments": .object(["query": .string("DROP TABLE users")])
        ])
        #expect(MCPRequestState.digest(ofParams: renamedTool) != MCPRequestState.digest(ofParams: base))
    }

    @Test("Absent params digest to the same empty value rather than throwing")
    func absentParamsDigest() {
        #expect(MCPRequestState.digest(ofParams: nil) == MCPRequestState.digest(ofParams: .object([:])))
        #expect(MCPRequestState.digest(ofParams: .string("not an object")) == MCPRequestState.digest(ofParams: nil))
    }
}
