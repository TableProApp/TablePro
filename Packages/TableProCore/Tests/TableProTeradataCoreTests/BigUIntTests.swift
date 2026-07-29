import XCTest
@testable import TableProTeradataCore

final class BigUIntTests: XCTestCase {
    func testRoundTripBytes() {
        XCTAssertEqual(BigUInt(hex: "")!.description, "0")
        XCTAssertEqual(BigUInt(hex: "00")!.description, "0")
        XCTAssertEqual(BigUInt(hex: "01")!.description, "01")
        XCTAssertEqual(BigUInt(hex: "ff")!.description, "ff")
        XCTAssertEqual(BigUInt(hex: "0100")!.description, "0100")
        XCTAssertEqual(BigUInt(hex: "deadbeef")!.description, "deadbeef")
        let prime = BigUInt(hex: DHVectors.primeHex)!
        XCTAssertEqual(prime.byteCount, 256)
        XCTAssertEqual(prime.description, DHVectors.primeHex.lowercased())
        XCTAssertEqual(BigUInt(bytesBE: prime.bytesBE()), prime)
    }

    func testComparisonAndSubtraction() {
        let a = BigUInt(hex: "1000000000000000")!
        let b = BigUInt(hex: "ffffffff")!
        XCTAssertEqual(BigUInt.compare(a.limbs, b.limbs), 1)
        XCTAssertEqual(BigUInt.compare(b.limbs, a.limbs), -1)
        XCTAssertEqual(BigUInt.compare(a.limbs, a.limbs), 0)
        XCTAssertEqual(a.subtracting(b).description, "0fffffff00000001")
    }

    func testModSmall() {
        XCTAssertEqual(BigUInt(hex: "64")!.mod(BigUInt(hex: "0a")!).description, "0")
        XCTAssertEqual(BigUInt(hex: "65")!.mod(BigUInt(hex: "0a")!).description, "01")
        XCTAssertEqual(BigUInt(hex: "deadbeefcafe")!.mod(BigUInt(hex: "010000")!).description, "cafe")
        XCTAssertEqual(BigUInt(hex: "123456789abcdef0")!.mod(BigUInt(hex: "0100000000")!).description,
                       "9abcdef0")
    }

    func testModPowSmallVectors() {
        for entry in DHVectors.small {
            let base = BigUInt(hex: entry.base)!
            let exp = BigUInt(hex: entry.exp)!
            let mod = BigUInt(hex: entry.mod)!
            let expected = BigUInt(hex: entry.result)!
            XCTAssertEqual(base.modPow(exp, modulus: mod), expected,
                           "\(entry.base)^\(entry.exp) mod \(entry.mod)")
        }
    }

    func testModPowDHVectors() {
        let prime = BigUInt(hex: DHVectors.primeHex)!
        let generator = BigUInt(hex: DHVectors.generatorHex)!
        for pair in DHVectors.pairs {
            let exp = BigUInt(hex: pair.x)!
            let expected = BigUInt(hex: pair.y)!
            XCTAssertEqual(generator.modPow(exp, modulus: prime), expected, "g^\(pair.x)")
        }
    }

    func testDiffieHellmanSharedSecretConsistency() {
        let prime = BigUInt(hex: DHVectors.primeHex)!
        let generator = BigUInt(hex: DHVectors.generatorHex)!
        let privateA = BigUInt(hex: "7f3c91aa20d5e6b8c4d1f0937755dd11abcdef0123456789fedcba9876543210")!
        let privateB = BigUInt(hex: "95e42b7d1c0a8f6e5d4c3b2a19087f6e5d4c3b2a1908f7e6d5c4b3a2918070605")!
        let publicA = generator.modPow(privateA, modulus: prime)
        let publicB = generator.modPow(privateB, modulus: prime)
        let sharedFromA = publicB.modPow(privateA, modulus: prime)
        let sharedFromB = publicA.modPow(privateB, modulus: prime)
        XCTAssertEqual(sharedFromA, sharedFromB)
        XCTAssertFalse(sharedFromA.isZero)
    }
}
