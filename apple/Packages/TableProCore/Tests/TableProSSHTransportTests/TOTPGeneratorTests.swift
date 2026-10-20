import Foundation
//
//  TOTPGeneratorTests.swift
//  TableProTests
//

import Testing

@testable import TableProSSHTransport

struct TOTPGeneratorTests {
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

    @Test func testSha1At59Seconds() {
        let generator = TOTPGenerator(secret: sha1Secret, algorithm: .sha1, digits: 8, period: 30)
        let date = Date(timeIntervalSince1970: 59)
        #expect(generator.generate(at: date) == "94287082")
    }

    @Test func testSha1At1111111109() {
        let generator = TOTPGenerator(secret: sha1Secret, algorithm: .sha1, digits: 8, period: 30)
        let date = Date(timeIntervalSince1970: 1_111_111_109)
        #expect(generator.generate(at: date) == "07081804")
    }

    @Test func testSha1At1111111111() {
        let generator = TOTPGenerator(secret: sha1Secret, algorithm: .sha1, digits: 8, period: 30)
        let date = Date(timeIntervalSince1970: 1_111_111_111)
        #expect(generator.generate(at: date) == "14050471")
    }

    @Test func testSha1At1234567890() {
        let generator = TOTPGenerator(secret: sha1Secret, algorithm: .sha1, digits: 8, period: 30)
        let date = Date(timeIntervalSince1970: 1_234_567_890)
        #expect(generator.generate(at: date) == "89005924")
    }

    @Test func testSha1At2000000000() {
        let generator = TOTPGenerator(secret: sha1Secret, algorithm: .sha1, digits: 8, period: 30)
        let date = Date(timeIntervalSince1970: 2_000_000_000)
        #expect(generator.generate(at: date) == "69279037")
    }

    // MARK: - RFC 6238 SHA256 Test Vectors (8 digits)

    @Test func testSha256At59Seconds() {
        let generator = TOTPGenerator(secret: sha256Secret, algorithm: .sha256, digits: 8, period: 30)
        let date = Date(timeIntervalSince1970: 59)
        #expect(generator.generate(at: date) == "46119246")
    }

    @Test func testSha256At1111111109() {
        let generator = TOTPGenerator(secret: sha256Secret, algorithm: .sha256, digits: 8, period: 30)
        let date = Date(timeIntervalSince1970: 1_111_111_109)
        #expect(generator.generate(at: date) == "68084774")
    }

    @Test func testSha256At1234567890() {
        let generator = TOTPGenerator(secret: sha256Secret, algorithm: .sha256, digits: 8, period: 30)
        let date = Date(timeIntervalSince1970: 1_234_567_890)
        #expect(generator.generate(at: date) == "91819424")
    }

    @Test func testSha256At2000000000() {
        let generator = TOTPGenerator(secret: sha256Secret, algorithm: .sha256, digits: 8, period: 30)
        let date = Date(timeIntervalSince1970: 2_000_000_000)
        #expect(generator.generate(at: date) == "90698825")
    }

    // MARK: - RFC 6238 SHA512 Test Vectors (8 digits)

    @Test func testSha512At59Seconds() {
        let generator = TOTPGenerator(secret: sha512Secret, algorithm: .sha512, digits: 8, period: 30)
        let date = Date(timeIntervalSince1970: 59)
        #expect(generator.generate(at: date) == "90693936")
    }

    @Test func testSha512At1111111109() {
        let generator = TOTPGenerator(secret: sha512Secret, algorithm: .sha512, digits: 8, period: 30)
        let date = Date(timeIntervalSince1970: 1_111_111_109)
        #expect(generator.generate(at: date) == "25091201")
    }

    @Test func testSha512At1234567890() {
        let generator = TOTPGenerator(secret: sha512Secret, algorithm: .sha512, digits: 8, period: 30)
        let date = Date(timeIntervalSince1970: 1_234_567_890)
        #expect(generator.generate(at: date) == "93441116")
    }

    @Test func testSha512At2000000000() {
        let generator = TOTPGenerator(secret: sha512Secret, algorithm: .sha512, digits: 8, period: 30)
        let date = Date(timeIntervalSince1970: 2_000_000_000)
        #expect(generator.generate(at: date) == "38618901")
    }

    // MARK: - 6-Digit Tests (last 6 digits of 8-digit result)

    @Test func testSixDigitSha1At59Seconds() {
        let generator = TOTPGenerator(secret: sha1Secret, algorithm: .sha1, digits: 6, period: 30)
        let date = Date(timeIntervalSince1970: 59)
        #expect(generator.generate(at: date) == "287082")
    }

    @Test func testSixDigitSha1At1111111109() {
        let generator = TOTPGenerator(secret: sha1Secret, algorithm: .sha1, digits: 6, period: 30)
        let date = Date(timeIntervalSince1970: 1_111_111_109)
        #expect(generator.generate(at: date) == "081804")
    }

    @Test func testSixDigitOutputLength() {
        let generator = TOTPGenerator(secret: sha1Secret, algorithm: .sha1, digits: 6, period: 30)
        let code = generator.generate(at: Date(timeIntervalSince1970: 59))
        #expect(code.count == 6)
    }

    @Test func testEightDigitOutputLength() {
        let generator = TOTPGenerator(secret: sha1Secret, algorithm: .sha1, digits: 8, period: 30)
        let code = generator.generate(at: Date(timeIntervalSince1970: 59))
        #expect(code.count == 8)
    }

    // MARK: - secondsRemaining

    @Test func testSecondsRemainingAtPeriodStart() {
        let generator = TOTPGenerator(secret: sha1Secret)
        // Timestamp 0 is exactly at a period boundary
        let date = Date(timeIntervalSince1970: 0)
        #expect(generator.secondsRemaining(at: date) == 30)
    }

    @Test func testSecondsRemainingMidPeriod() {
        let generator = TOTPGenerator(secret: sha1Secret)
        let date = Date(timeIntervalSince1970: 10)
        #expect(generator.secondsRemaining(at: date) == 20)
    }

    @Test func testSecondsRemainingNearEnd() {
        let generator = TOTPGenerator(secret: sha1Secret)
        let date = Date(timeIntervalSince1970: 29)
        #expect(generator.secondsRemaining(at: date) == 1)
    }

    // MARK: - fromBase32Secret

    @Test func testFromBase32SecretValid() {
        // "GEZDGNBVGY3TQOJQ" is base32 for "12345678901234" (14 bytes)
        let generator = TOTPGenerator.fromBase32Secret("GEZDGNBVGY3TQOJQ")
        #expect(generator != nil)
    }

    @Test func testFromBase32SecretWithSpaces() {
        let clean = TOTPGenerator.fromBase32Secret("GEZDGNBVGY3TQOJQ")
        let spaced = TOTPGenerator.fromBase32Secret("GEZD GNBV GY3T QOJQ")
        #expect(clean != nil)
        #expect(spaced != nil)
        // Both should produce the same code at any given time
        let date = Date(timeIntervalSince1970: 59)
        #expect(clean?.generate(at: date) == spaced?.generate(at: date))
    }

    @Test(arguments: ["!!!invalid!!!", ""])
    func testFromBase32SecretInvalidOrEmpty(_ secret: String) {
        let generator = TOTPGenerator.fromBase32Secret(secret)
        #expect(generator == nil)
    }

    @Test("Digits or a period no authenticator uses give no generator instead of a trap", arguments: [
        (6, 0), (6, -30), (5, 30), (9, 30), (10, 30), (-1, 30),
    ])
    func unsupportedSettingsAreRefused(digits: Int, period: Int) {
        #expect(TOTPGenerator.fromBase32Secret("GEZDGNBVGY3TQOJQ", digits: digits, period: period) == nil)
    }

    // MARK: - Default Parameters

    @Test func testDefaultAlgorithm() {
        let generator = TOTPGenerator(secret: sha1Secret)
        // Default is SHA1, 6 digits, 30s period
        let date = Date(timeIntervalSince1970: 59)
        // 6-digit SHA1 at T=59 should be "287082"
        #expect(generator.generate(at: date) == "287082")
    }

    // MARK: - Code Changes at Period Boundary

    @Test func testCodeChangesAtPeriodBoundary() {
        let generator = TOTPGenerator(secret: sha1Secret, algorithm: .sha1, digits: 8, period: 30)
        let beforeBoundary = Date(timeIntervalSince1970: 59)
        let afterBoundary = Date(timeIntervalSince1970: 60)
        let codeBefore = generator.generate(at: beforeBoundary)
        let codeAfter = generator.generate(at: afterBoundary)
        // T=59 → counter 1, T=60 → counter 2 — different codes
        #expect(codeBefore != codeAfter)
    }
}
