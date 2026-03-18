//
//  Base32Tests.swift
//  TableProTests
//

@testable import TablePro
import XCTest

final class Base32Tests: XCTestCase {
    // MARK: - RFC 4648 Test Vectors

    func testDecodeEmptyString() {
        let result = Base32.decode("")
        XCTAssertNotNil(result)
        XCTAssertEqual(result, Data())
    }

    func testDecodeSingleCharacter() {
        // "MY" → "f" (0x66)
        let result = Base32.decode("MY")
        XCTAssertEqual(result, Data([0x66]))
    }

    func testDecodeTwoCharacters() {
        // "MZXQ" → "fo"
        let result = Base32.decode("MZXQ")
        XCTAssertEqual(result, Data("fo".utf8))
    }

    func testDecodeThreeCharacters() {
        // "MZXW6" → "foo"
        let result = Base32.decode("MZXW6")
        XCTAssertEqual(result, Data("foo".utf8))
    }

    func testDecodeFourCharacters() {
        // "MZXW6YQ" → "foob"
        let result = Base32.decode("MZXW6YQ")
        XCTAssertEqual(result, Data("foob".utf8))
    }

    func testDecodeFiveCharacters() {
        // "MZXW6YTB" → "fooba"
        let result = Base32.decode("MZXW6YTB")
        XCTAssertEqual(result, Data("fooba".utf8))
    }

    func testDecodeSixCharacters() {
        // "MZXW6YTBOI" → "foobar"
        let result = Base32.decode("MZXW6YTBOI")
        XCTAssertEqual(result, Data("foobar".utf8))
    }

    // MARK: - Case Insensitivity

    func testDecodeLowercase() {
        let result = Base32.decode("mzxw6ytboi")
        XCTAssertEqual(result, Data("foobar".utf8))
    }

    func testDecodeMixedCase() {
        let result = Base32.decode("MzXw6YtBoI")
        XCTAssertEqual(result, Data("foobar".utf8))
    }

    // MARK: - Padding

    func testDecodeWithPadding() {
        let result = Base32.decode("MZXW6YTBOI======")
        XCTAssertEqual(result, Data("foobar".utf8))
    }

    func testDecodeWithPartialPadding() {
        let result = Base32.decode("MY======")
        XCTAssertEqual(result, Data([0x66]))
    }

    // MARK: - Whitespace and Dashes

    func testDecodeWithSpaces() {
        let result = Base32.decode("MZXW 6YTB OI")
        XCTAssertEqual(result, Data("foobar".utf8))
    }

    func testDecodeWithDashes() {
        let result = Base32.decode("MZXW-6YTB-OI")
        XCTAssertEqual(result, Data("foobar".utf8))
    }

    func testDecodeWithSpacesAndDashes() {
        let result = Base32.decode("MZXW - 6YTB - OI")
        XCTAssertEqual(result, Data("foobar".utf8))
    }

    func testDecodeWithTabs() {
        let result = Base32.decode("MZXW6\tYTBOI")
        XCTAssertEqual(result, Data("foobar".utf8))
    }

    // MARK: - Invalid Input

    func testDecodeInvalidCharacter() {
        let result = Base32.decode("1")
        XCTAssertNil(result)
    }

    func testDecodeInvalidCharacterInMiddle() {
        let result = Base32.decode("MF!GG")
        XCTAssertNil(result)
    }

    // MARK: - Real-World TOTP Secrets

    func testDecodeTypicalTotpSecret() {
        // "JBSWY3DPEHPK3PXP" is a common TOTP example secret
        let result = Base32.decode("JBSWY3DPEHPK3PXP")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.count, 10)
    }

    func testDecodeSecretWithSpacesAndDashes() {
        // Same secret formatted as users might copy it
        let clean = Base32.decode("JBSWY3DPEHPK3PXP")
        let withFormatting = Base32.decode("JBSW Y3DP-EHPK-3PXP")
        XCTAssertEqual(clean, withFormatting)
    }
}
