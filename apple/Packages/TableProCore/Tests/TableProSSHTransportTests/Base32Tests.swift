import Foundation
//
//  Base32Tests.swift
//  TableProTests
//

import Testing

@testable import TableProSSHTransport

struct Base32Tests {
    // MARK: - RFC 4648 Test Vectors

    @Test func testDecodeEmptyString() {
        let result = Base32.decode("")
        #expect(result != nil)
        #expect(result == Data())
    }

    @Test(arguments: ["MY", "MY======"])
    func testDecodeSingleCharacter(_ encoded: String) {
        let result = Base32.decode(encoded)
        #expect(result == Data([0x66]))
    }

    @Test func testDecodeTwoCharacters() {
        // "MZXQ" → "fo"
        let result = Base32.decode("MZXQ")
        #expect(result == Data("fo".utf8))
    }

    @Test func testDecodeThreeCharacters() {
        // "MZXW6" → "foo"
        let result = Base32.decode("MZXW6")
        #expect(result == Data("foo".utf8))
    }

    @Test func testDecodeFourCharacters() {
        // "MZXW6YQ" → "foob"
        let result = Base32.decode("MZXW6YQ")
        #expect(result == Data("foob".utf8))
    }

    @Test func testDecodeFiveCharacters() {
        // "MZXW6YTB" → "fooba"
        let result = Base32.decode("MZXW6YTB")
        #expect(result == Data("fooba".utf8))
    }

    @Test func testDecodeSixCharacters() {
        // "MZXW6YTBOI" → "foobar"
        let result = Base32.decode("MZXW6YTBOI")
        #expect(result == Data("foobar".utf8))
    }

    // MARK: - Case Insensitivity

    @Test func testDecodeLowercase() {
        let result = Base32.decode("mzxw6ytboi")
        #expect(result == Data("foobar".utf8))
    }

    @Test func testDecodeMixedCase() {
        let result = Base32.decode("MzXw6YtBoI")
        #expect(result == Data("foobar".utf8))
    }

    // MARK: - Padding

    @Test func testDecodeWithPadding() {
        let result = Base32.decode("MZXW6YTBOI======")
        #expect(result == Data("foobar".utf8))
    }

    // MARK: - Whitespace and Dashes

    @Test func testDecodeWithSpaces() {
        let result = Base32.decode("MZXW 6YTB OI")
        #expect(result == Data("foobar".utf8))
    }

    @Test func testDecodeWithDashes() {
        let result = Base32.decode("MZXW-6YTB-OI")
        #expect(result == Data("foobar".utf8))
    }

    @Test func testDecodeWithSpacesAndDashes() {
        let result = Base32.decode("MZXW - 6YTB - OI")
        #expect(result == Data("foobar".utf8))
    }

    @Test func testDecodeWithTabs() {
        let result = Base32.decode("MZXW6\tYTBOI")
        #expect(result == Data("foobar".utf8))
    }

    // MARK: - Invalid Input

    @Test(arguments: ["1", "MF!GG"])
    func testDecodeInvalidCharacter(_ encoded: String) {
        let result = Base32.decode(encoded)
        #expect(result == nil)
    }

    // MARK: - Real-World TOTP Secrets

    @Test func testDecodeTypicalTotpSecret() {
        // "JBSWY3DPEHPK3PXP" is a common TOTP example secret
        let result = Base32.decode("JBSWY3DPEHPK3PXP")
        #expect(result != nil)
        #expect(result?.count == 10)
    }

    @Test func testDecodeSecretWithSpacesAndDashes() {
        // Same secret formatted as users might copy it
        let clean = Base32.decode("JBSWY3DPEHPK3PXP")
        let withFormatting = Base32.decode("JBSW Y3DP-EHPK-3PXP")
        #expect(clean == withFormatting)
    }
}
