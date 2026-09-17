@testable import TableProTeradataCore
import XCTest

final class BigUIntTests: XCTestCase {
    private func bigUInt(_ hex: String, file: StaticString = #filePath, line: UInt = #line) throws -> BigUInt {
        try XCTUnwrap(BigUInt(hex: hex), file: file, line: line)
    }

    func testRoundTripBytes() throws {
        XCTAssertEqual(try bigUInt("").description, "0")
        XCTAssertEqual(try bigUInt("00").description, "0")
        XCTAssertEqual(try bigUInt("01").description, "01")
        XCTAssertEqual(try bigUInt("ff").description, "ff")
        XCTAssertEqual(try bigUInt("0100").description, "0100")
        XCTAssertEqual(try bigUInt("deadbeef").description, "deadbeef")
        let prime = try bigUInt(DHVectors.primeHex)
        XCTAssertEqual(prime.byteCount, 256)
        XCTAssertEqual(prime.description, DHVectors.primeHex.lowercased())
        XCTAssertEqual(BigUInt(bytesBE: prime.bytesBE()), prime)
    }

    func testComparisonAndSubtraction() throws {
        let a = try bigUInt("1000000000000000")
        let b = try bigUInt("ffffffff")
        XCTAssertEqual(BigUInt.compare(a.limbs, b.limbs), 1)
        XCTAssertEqual(BigUInt.compare(b.limbs, a.limbs), -1)
        XCTAssertEqual(BigUInt.compare(a.limbs, a.limbs), 0)
        XCTAssertEqual(a.subtracting(b).description, "0fffffff00000001")
    }

    func testModSmall() throws {
        XCTAssertEqual(try bigUInt("64").mod(bigUInt("0a")).description, "0")
        XCTAssertEqual(try bigUInt("65").mod(bigUInt("0a")).description, "01")
        XCTAssertEqual(try bigUInt("deadbeefcafe").mod(bigUInt("010000")).description, "cafe")
        XCTAssertEqual(try bigUInt("123456789abcdef0").mod(bigUInt("0100000000")).description,
                       "9abcdef0")
    }

    func testModPowSmallVectors() throws {
        for entry in DHVectors.small {
            let base = try bigUInt(entry.base)
            let exp = try bigUInt(entry.exp)
            let mod = try bigUInt(entry.mod)
            let expected = try bigUInt(entry.result)
            XCTAssertEqual(base.modPow(exp, modulus: mod), expected,
                           "\(entry.base)^\(entry.exp) mod \(entry.mod)")
        }
    }

    func testModPowDHVectors() throws {
        let prime = try bigUInt(DHVectors.primeHex)
        let generator = try bigUInt(DHVectors.generatorHex)
        for pair in DHVectors.pairs {
            let exp = try bigUInt(pair.x)
            let expected = try bigUInt(pair.y)
            XCTAssertEqual(generator.modPow(exp, modulus: prime), expected, "g^\(pair.x)")
        }
    }

    func testDiffieHellmanSharedSecretConsistency() throws {
        let prime = try bigUInt(DHVectors.primeHex)
        let generator = try bigUInt(DHVectors.generatorHex)
        let privateA = try bigUInt("7f3c91aa20d5e6b8c4d1f0937755dd11abcdef0123456789fedcba9876543210")
        let privateB = try bigUInt("95e42b7d1c0a8f6e5d4c3b2a19087f6e5d4c3b2a1908f7e6d5c4b3a2918070605")
        let publicA = generator.modPow(privateA, modulus: prime)
        let publicB = generator.modPow(privateB, modulus: prime)
        let sharedFromA = publicB.modPow(privateA, modulus: prime)
        let sharedFromB = publicA.modPow(privateB, modulus: prime)
        XCTAssertEqual(sharedFromA, sharedFromB)
        XCTAssertFalse(sharedFromA.isZero)
    }
}
