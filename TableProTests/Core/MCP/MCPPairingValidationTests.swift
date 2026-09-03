//
//  MCPPairingValidationTests.swift
//  TableProTests
//
//  The redirect decides who ends up holding the pairing code, so only the two shapes that reach the
//  machine the user is sitting at are accepted: a loopback HTTP listener (RFC 8252) and a
//  private-use scheme an installed app registered. Anything else is a web page. PKCE is checked
//  against RFC 7636 on both halves before either value reaches a comparison, and approving a
//  request never touches a token that happens to share the requester's client name.
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("MCP Pairing Validation")
struct MCPPairingValidationTests {
    private func url(_ value: String) throws -> URL {
        try #require(URL(string: value))
    }

    @Test("A loopback HTTP callback is accepted and shows its host")
    func loopbackHttpAccepted() throws {
        let target = try PairingRedirectValidator.validate(url("http://127.0.0.1:8765/callback"))
        #expect(target.kind == .loopbackHttp)
        #expect(target.displayValue == "http://127.0.0.1:8765/callback")
    }

    @Test("Every loopback spelling is accepted over HTTP and HTTPS")
    func loopbackSpellingsAccepted() throws {
        for host in ["127.0.0.1", "localhost", "[::1]"] {
            for scheme in ["http", "https"] {
                let target = try PairingRedirectValidator.validate(url("\(scheme)://\(host):9000/cb"))
                #expect(target.kind == .loopbackHttp)
            }
        }
    }

    @Test("A remote HTTPS callback is refused")
    func remoteHttpsRefused() throws {
        let redirect = try url("https://evil.example.com/callback")
        #expect(throws: PairingValidationError.redirectHostNotLoopback("evil.example.com")) {
            try PairingRedirectValidator.validate(redirect)
        }
    }

    @Test("An HTTP callback with no host at all is refused")
    func hostlessHttpRefused() throws {
        let redirect = try url("http:///callback")
        #expect(throws: PairingValidationError.redirectHostNotLoopback("-")) {
            try PairingRedirectValidator.validate(redirect)
        }
    }

    @Test("Userinfo dressed up as loopback is refused")
    func userinfoRefused() throws {
        let redirect = try url("http://127.0.0.1@evil.example.com/callback")
        #expect(throws: PairingValidationError.redirectCarriesCredentials) {
            try PairingRedirectValidator.validate(redirect)
        }
    }

    @Test("A registered private-use scheme stays supported")
    func privateUseSchemeAccepted() throws {
        let target = try PairingRedirectValidator.validate(
            url("raycast://extensions/ngoquocdat/tablepro/pair-callback")
        )
        #expect(target.kind == .privateUseScheme)
        #expect(target.displayValue.hasPrefix("raycast://"))
    }

    @Test("A scheme that can execute or read locally is refused")
    func dangerousSchemesRefused() throws {
        for scheme in ["javascript", "data", "file", "vbscript", "about", "blob", "ftp"] {
            let redirect = try url("\(scheme)://x/callback")
            #expect(throws: PairingValidationError.redirectSchemeNotAllowed(scheme)) {
                try PairingRedirectValidator.validate(redirect)
            }
        }
    }

    @Test("A verifier outside the RFC 7636 length is refused")
    func verifierLengthIsEnforced() {
        #expect(throws: PairingValidationError.verifierMalformed) {
            try PairingPkceValidator.validateVerifier(String(repeating: "a", count: 42))
        }
        #expect(throws: PairingValidationError.verifierMalformed) {
            try PairingPkceValidator.validateVerifier(String(repeating: "a", count: 129))
        }
    }

    @Test("A verifier outside the unreserved set is refused")
    func nonUnreservedVerifierRefused() {
        for suffix in ["/", "+", "=", " ", "é"] {
            #expect(throws: PairingValidationError.verifierMalformed) {
                try PairingPkceValidator.validateVerifier(String(repeating: "a", count: 42) + suffix)
            }
        }
    }

    @Test("A verifier at either end of the allowed range is accepted")
    func boundaryVerifiersAccepted() throws {
        try PairingPkceValidator.validateVerifier(String(repeating: "a", count: 43))
        try PairingPkceValidator.validateVerifier(String(repeating: "a", count: 128))
        try PairingPkceValidator.validateVerifier(String(repeating: "-._~", count: 32))
    }

    @Test("A challenge that is not a base64url SHA-256 is refused")
    func malformedChallengeRefused() {
        #expect(throws: PairingValidationError.challengeMalformed) {
            try PairingPkceValidator.validateChallenge("too-short")
        }
        #expect(throws: PairingValidationError.challengeMalformed) {
            try PairingPkceValidator.validateChallenge(String(repeating: "a", count: 44))
        }
        #expect(throws: PairingValidationError.challengeMalformed) {
            try PairingPkceValidator.validateChallenge(String(repeating: "a", count: 42) + "=")
        }
    }

    @Test("The challenge of a well formed verifier passes its own check")
    func realChallengeIsAccepted() throws {
        let verifier = String(repeating: "a", count: 43)
        try PairingPkceValidator.validateChallenge(PairingExchangeStore.sha256Base64Url(of: verifier))
    }

    @Test("A failed verification burns the code")
    func failedVerificationBurnsCode() async throws {
        let store = PairingExchangeStore()
        let verifier = String(repeating: "a", count: 43)
        let record = PairingExchangeRecord(
            plaintextToken: "tp_secret",
            tokenId: UUID(),
            challenge: PairingExchangeStore.sha256Base64Url(of: verifier),
            expiresAt: Date.now.addingTimeInterval(300)
        )
        try await store.insert(code: "code-1", record: record)

        await #expect(throws: DatabaseAccessError.self) {
            _ = try await store.consume(code: "code-1", verifier: String(repeating: "b", count: 43))
        }
        #expect(await store.contains(code: "code-1") == false)

        await #expect(throws: DatabaseAccessError.self) {
            _ = try await store.consume(code: "code-1", verifier: verifier)
        }
    }

    @Test("A matching verifier releases the token exactly once")
    func matchingVerifierReleasesToken() async throws {
        let store = PairingExchangeStore()
        let verifier = String(repeating: "a", count: 43)
        let tokenId = UUID()
        try await store.insert(
            code: "code-2",
            record: PairingExchangeRecord(
                plaintextToken: "tp_secret",
                tokenId: tokenId,
                challenge: PairingExchangeStore.sha256Base64Url(of: verifier),
                expiresAt: Date.now.addingTimeInterval(300)
            )
        )

        let record = try await store.consume(code: "code-2", verifier: verifier)
        #expect(record.plaintextToken == "tp_secret")
        #expect(record.tokenId == tokenId)
        #expect(await store.contains(code: "code-2") == false)
    }

    @Test("A refused redirect is reported by its reason, never by its address")
    func refusalReasonsAreStable() {
        #expect(PairingValidationError.redirectSchemeMissing.reason == "redirect_scheme_missing")
        #expect(
            PairingValidationError.redirectHostNotLoopback("evil.example.com").reason
                == "redirect_host_not_loopback:evil.example.com"
        )
        #expect(PairingValidationError.redirectCarriesCredentials.reason == "redirect_carries_credentials")
        for error: PairingValidationError in [
            .redirectSchemeMissing,
            .redirectSchemeNotAllowed("javascript"),
            .redirectHostNotLoopback("evil.example.com"),
            .redirectCarriesCredentials
        ] {
            #expect(error.localizedMessage.isEmpty == false)
        }
    }

    @Test("Approving a pairing request never revokes a token that shares the client name")
    func approvingNeverRevokesBySharedName() throws {
        let source = try Self.pairingServiceSource()

        #expect(source.contains("revokeExistingTokens") == false)
        #expect(source.contains(".revoke(") == false)
    }

    private static func pairingServiceSource() throws -> String {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<12 {
            let candidate = directory.appendingPathComponent("TablePro/Core/MCP/MCPPairingService.swift")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            directory = directory.deletingLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
