//
//  StringSHA256Tests.swift
//  TableProTests
//
//  Tests for String SHA256 extension
//

import CryptoKit
import Foundation
import Testing

@testable import TablePro

@Suite("String SHA256")
struct StringSHA256Tests {
    @Test("Known hash for 'hello'")
    func testKnownHash() {
        let input = "hello"
        let expectedHash = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"

        let result = input.sha256

        #expect(result == expectedHash)
    }

    @Test("Empty string hash")
    func testEmptyStringHash() {
        let input = ""
        let expectedHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

        let result = input.sha256

        #expect(result == expectedHash)
    }

    @Test("Determinism: same input produces same output")
    func testDeterminism() {
        let input = "test string"

        let result1 = input.sha256
        let result2 = input.sha256

        #expect(result1 == result2)
    }

    @Test("Different inputs produce different outputs")
    func testDifferentInputs() {
        let input1 = "hello"
        let input2 = "world"

        let hash1 = input1.sha256
        let hash2 = input2.sha256

        #expect(hash1 != hash2)
    }

    @Test("Unicode string hashes consistently")
    func testUnicodeHash() {
        let input = "Xin chào 🇻🇳"

        let result1 = input.sha256
        let result2 = input.sha256

        #expect(result1 == result2)
        #expect(result1.count == 64) // SHA256 produces 64 hex characters
    }
}
