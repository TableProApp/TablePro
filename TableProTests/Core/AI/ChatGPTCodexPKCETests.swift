//
//  ChatGPTCodexPKCETests.swift
//  TableProTests
//

import CryptoKit
import Foundation
@testable import TablePro
import Testing

@Suite("ChatGPTCodexPKCE")
struct ChatGPTCodexPKCETests {
    @Test("Verifier length is within the RFC 7636 range")
    func verifierLength() {
        let pkce = ChatGPTCodexPKCE()
        #expect(pkce.verifier.count >= 43)
        #expect(pkce.verifier.count <= 128)
    }

    @Test("Challenge is the base64url SHA-256 of the verifier")
    func challengeMatchesVerifier() {
        let pkce = ChatGPTCodexPKCE()
        let digest = SHA256.hash(data: Data(pkce.verifier.utf8))
        let expected = ChatGPTCodexBase64URL.encode(Data(digest))
        #expect(pkce.challenge == expected)
    }

    @Test("Challenge and state contain no base64 padding or unsafe characters")
    func urlSafeOutput() {
        let pkce = ChatGPTCodexPKCE()
        for value in [pkce.verifier, pkce.challenge, pkce.state] {
            #expect(!value.contains("="))
            #expect(!value.contains("+"))
            #expect(!value.contains("/"))
        }
    }

    @Test("Each instance produces a distinct verifier and state")
    func uniquePerInstance() {
        let first = ChatGPTCodexPKCE()
        let second = ChatGPTCodexPKCE()
        #expect(first.verifier != second.verifier)
        #expect(first.state != second.state)
    }
}
