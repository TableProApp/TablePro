//
//  TOTPGeneratorTests.swift
//  TableProTests
//

import XCTest

@testable import TablePro

final class TOTPGeneratorTests: XCTestCase {
    // MARK: - RFC 6238 SHA1 Test Vectors (8 digits)

    /// RFC 6238 SHA1 secret: "12345678901234567890" (20 bytes ASCII)
    private var sha1Secret: Data {
        Data("12345678901234567890".utf8)
    }

    /// RFC 6238 SHA256 secret: "12345678901234567890123456789012" (32 bytes ASCII)
    private var sha256Secret: Data {
        Data("12345678901234567890123456789012".utf8)
    }

    /// RFC 6238 SHA512 secret: "1234567890123456789012345678901234567890123456789012345678901234" (64 bytes ASCII)
    private var sha512Secret: Data {
        Data("1234567890123456789012345678901234567890123456789012345678901234".utf8)
    }

    func testSha1At59Seconds() {
        let generator = TOTPGenerator(secret: sha1Secret, algorithm: .sha1, digits: 8, period: 30)
        let date = Date(timeIntervalSince1970: 59)
        XCTAssertEqual(generator.generate(at: date), "94287082")
    }

    func testSha1At1111111109() {
        let generator = TOTPGenerator(secret: sha1Secret, algorithm: .sha1, digits: 8, period: 30)
        let date = Date(timeIntervalSince1970: 1_111_111_109)
        XCTAssertEqual(generator.generate(at: date), "07081804")
    }

    func testSha1At1111111111() {
        let generator = TOTPGenerator(secret: sha1Secret, algorithm: .sha1, digits: 8, period: 30)
        let date = Date(timeIntervalSince1970: 1_111_111_111)
        XCTAssertEqual(generator.generate(at: date), "14050471")
    }

    func testSha1At1234567890() {
        let generator = TOTPGenerator(secret: sha1Secret, algorithm: .sha1, digits: 8, period: 30)
        let date = Date(timeIntervalSince1970: 1_234_567_890)
        XCTAssertEqual(generator.generate(at: date), "89005924")
    }

    func testSha1At2000000000() {
        let generator = TOTPGenerator(secret: sha1Secret, algorithm: .sha1, digits: 8, period: 30)
        let date = Date(timeIntervalSince1970: 2_000_000_000)
        XCTAssertEqual(generator.generate(at: date), "69279037")
    }

    // MARK: - RFC 6238 SHA256 Test Vectors (8 digits)

    func testSha256At59Seconds() {
        let generator = TOTPGenerator(secret: sha256Secret, algorithm: .sha256, digits: 8, period: 30)
        let date = Date(timeIntervalSince1970: 59)
        XCTAssertEqual(generator.generate(at: date), "46119246")
    }

    func testSha256At1111111109() {
        let generator = TOTPGenerator(secret: sha256Secret, algorithm: .sha256, digits: 8, period: 30)
        let date = Date(timeIntervalSince1970: 1_111_111_109)
        XCTAssertEqual(generator.generate(at: date), "68084774")
    }

    func testSha256At1234567890() {
        let generator = TOTPGenerator(secret: sha256Secret, algorithm: .sha256, digits: 8, period: 30)
        let date = Date(timeIntervalSince1970: 1_234_567_890)
        XCTAssertEqual(generator.generate(at: date), "91819424")
    }

    func testSha256At2000000000() {
        let generator = TOTPGenerator(secret: sha256Secret, algorithm: .sha256, digits: 8, period: 30)
        let date = Date(timeIntervalSince1970: 2_000_000_000)
        XCTAssertEqual(generator.generate(at: date), "90698825")
    }

    // MARK: - RFC 6238 SHA512 Test Vectors (8 digits)

    func testSha512At59Seconds() {
        let generator = TOTPGenerator(secret: sha512Secret, algorithm: .sha512, digits: 8, period: 30)
        let date = Date(timeIntervalSince1970: 59)
        XCTAssertEqual(generator.generate(at: date), "90693936")
    }

    func testSha512At1111111109() {
        let generator = TOTPGenerator(secret: sha512Secret, algorithm: .sha512, digits: 8, period: 30)
        let date = Date(timeIntervalSince1970: 1_111_111_109)
        XCTAssertEqual(generator.generate(at: date), "25091201")
    }

    func testSha512At1234567890() {
        let generator = TOTPGenerator(secret: sha512Secret, algorithm: .sha512, digits: 8, period: 30)
        let date = Date(timeIntervalSince1970: 1_234_567_890)
        XCTAssertEqual(generator.generate(at: date), "93441116")
    }

    func testSha512At2000000000() {
        let generator = TOTPGenerator(secret: sha512Secret, algorithm: .sha512, digits: 8, period: 30)
        let date = Date(timeIntervalSince1970: 2_000_000_000)
        XCTAssertEqual(generator.generate(at: date), "38618901")
    }

    // MARK: - 6-Digit Tests (last 6 digits of 8-digit result)

    func testSixDigitSha1At59Seconds() {
        let generator = TOTPGenerator(secret: sha1Secret, algorithm: .sha1, digits: 6, period: 30)
        let date = Date(timeIntervalSince1970: 59)
        XCTAssertEqual(generator.generate(at: date), "287082")
    }

    func testSixDigitSha1At1111111109() {
        let generator = TOTPGenerator(secret: sha1Secret, algorithm: .sha1, digits: 6, period: 30)
        let date = Date(timeIntervalSince1970: 1_111_111_109)
        XCTAssertEqual(generator.generate(at: date), "081804")
    }

    func testSixDigitOutputLength() {
        let generator = TOTPGenerator(secret: sha1Secret, algorithm: .sha1, digits: 6, period: 30)
        let code = generator.generate(at: Date(timeIntervalSince1970: 59))
        XCTAssertEqual(code.count, 6)
    }

    func testEightDigitOutputLength() {
        let generator = TOTPGenerator(secret: sha1Secret, algorithm: .sha1, digits: 8, period: 30)
        let code = generator.generate(at: Date(timeIntervalSince1970: 59))
        XCTAssertEqual(code.count, 8)
    }

    // MARK: - secondsRemaining

    func testSecondsRemainingAtPeriodStart() {
        let generator = TOTPGenerator(secret: sha1Secret)
        // Timestamp 0 is exactly at a period boundary
        let date = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(generator.secondsRemaining(at: date), 30)
    }

    func testSecondsRemainingMidPeriod() {
        let generator = TOTPGenerator(secret: sha1Secret)
        let date = Date(timeIntervalSince1970: 10)
        XCTAssertEqual(generator.secondsRemaining(at: date), 20)
    }

    func testSecondsRemainingNearEnd() {
        let generator = TOTPGenerator(secret: sha1Secret)
        let date = Date(timeIntervalSince1970: 29)
        XCTAssertEqual(generator.secondsRemaining(at: date), 1)
    }

    // MARK: - fromBase32Secret

    func testFromBase32SecretValid() {
        // "GEZDGNBVGY3TQOJQ" is base32 for "12345678901234" (14 bytes)
        let generator = TOTPGenerator.fromBase32Secret("GEZDGNBVGY3TQOJQ")
        XCTAssertNotNil(generator)
    }

    func testFromBase32SecretWithSpaces() {
        let clean = TOTPGenerator.fromBase32Secret("GEZDGNBVGY3TQOJQ")
        let spaced = TOTPGenerator.fromBase32Secret("GEZD GNBV GY3T QOJQ")
        XCTAssertNotNil(clean)
        XCTAssertNotNil(spaced)
        // Both should produce the same code at any given time
        let date = Date(timeIntervalSince1970: 59)
        XCTAssertEqual(clean?.generate(at: date), spaced?.generate(at: date))
    }

    func testFromBase32SecretInvalid() {
        let generator = TOTPGenerator.fromBase32Secret("!!!invalid!!!")
        XCTAssertNil(generator)
    }

    func testFromBase32SecretEmpty() {
        let generator = TOTPGenerator.fromBase32Secret("")
        XCTAssertNil(generator)
    }

    // MARK: - Default Parameters

    func testDefaultAlgorithm() {
        let generator = TOTPGenerator(secret: sha1Secret)
        // Default is SHA1, 6 digits, 30s period
        let date = Date(timeIntervalSince1970: 59)
        // 6-digit SHA1 at T=59 should be "287082"
        XCTAssertEqual(generator.generate(at: date), "287082")
    }

    // MARK: - Code Changes at Period Boundary

    func testCodeChangesAtPeriodBoundary() {
        let generator = TOTPGenerator(secret: sha1Secret, algorithm: .sha1, digits: 8, period: 30)
        let beforeBoundary = Date(timeIntervalSince1970: 59)
        let afterBoundary = Date(timeIntervalSince1970: 60)
        let codeBefore = generator.generate(at: beforeBoundary)
        let codeAfter = generator.generate(at: afterBoundary)
        // T=59 → counter 1, T=60 → counter 2 — different codes
        XCTAssertNotEqual(codeBefore, codeAfter)
    }
}
