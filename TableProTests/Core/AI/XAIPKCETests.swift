//
//  XAIPKCETests.swift
//  TableProTests
//

import CryptoKit
import Foundation
@testable import TablePro
import Testing

@Suite("XAIPKCE")
struct XAIPKCETests {
    @Test("Verifier length is within the RFC 7636 range")
    func verifierLength() {
        let pkce = XAIPKCE()
        #expect(pkce.verifier.count >= 43)
        #expect(pkce.verifier.count <= 128)
    }

    @Test("Challenge is the base64url SHA-256 of the verifier")
    func challengeMatchesVerifier() {
        let pkce = XAIPKCE()
        let digest = SHA256.hash(data: Data(pkce.verifier.utf8))
        let expected = XAIBase64URL.encode(Data(digest))
        #expect(pkce.challenge == expected)
    }

    @Test("Challenge, verifier, and state contain no base64 padding or unsafe characters")
    func urlSafeOutput() {
        let pkce = XAIPKCE()
        for value in [pkce.verifier, pkce.challenge, pkce.state] {
            #expect(!value.contains("="))
            #expect(!value.contains("+"))
            #expect(!value.contains("/"))
        }
    }

    @Test("Each instance produces a distinct verifier and state")
    func uniquePerInstance() {
        let first = XAIPKCE()
        let second = XAIPKCE()
        #expect(first.verifier != second.verifier)
        #expect(first.state != second.state)
    }
}
