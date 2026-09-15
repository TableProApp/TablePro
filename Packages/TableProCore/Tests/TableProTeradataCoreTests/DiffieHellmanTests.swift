@testable import TableProTeradataCore
import XCTest

final class DiffieHellmanTests: XCTestCase {
    private func bytesBE(ofHex hex: String, file: StaticString = #filePath, line: UInt = #line) throws -> [UInt8] {
        try XCTUnwrap(BigUInt(hex: hex), file: file, line: line).bytesBE()
    }

    private func primeBytes(file: StaticString = #filePath, line: UInt = #line) throws -> [UInt8] {
        try bytesBE(ofHex: DHVectors.primeHex, file: file, line: line)
    }

    func testSharedSecretMatches() throws {
        let prime = try primeBytes()
        let exponentA = try bytesBE(ofHex: "a1b2c3d4e5f6071829")
        let exponentB = try bytesBE(ofHex: "0f1e2d3c4b5a69788796a5b4c3d2e1f0")
        let dhA = DiffieHellman(primeBytes: prime, generatorBytes: [0x02], privateExponentBytes: exponentA)
        let dhB = DiffieHellman(primeBytes: prime, generatorBytes: [0x02], privateExponentBytes: exponentB)
        let sharedA = dhA.sharedSecret(peerPublicKeyBytes: dhB.publicKeyBytes())
        let sharedB = dhB.sharedSecret(peerPublicKeyBytes: dhA.publicKeyBytes())
        XCTAssertEqual(sharedA, sharedB)
        XCTAssertEqual(dhA.publicKeyBytes().count, 256)
        XCTAssertEqual(sharedA.count, 256)
    }

    func testRandomExponentIsUnique() throws {
        let dh1 = DiffieHellman(primeBytes: try primeBytes(), generatorBytes: [0x02])
        let dh2 = DiffieHellman(primeBytes: try primeBytes(), generatorBytes: [0x02])
        XCTAssertNotEqual(dh1.publicKeyBytes(), dh2.publicKeyBytes())
    }

    func testDeriveKeySlice() {
        let secret = (0..<32).map { UInt8($0) }
        XCTAssertEqual(DiffieHellman.deriveKey(fromSharedSecret: secret, offset: 0, length: 16),
                       Array(0..<16).map(UInt8.init))
        XCTAssertEqual(DiffieHellman.deriveKey(fromSharedSecret: secret, offset: 16, length: 8),
                       Array(16..<24).map(UInt8.init))
    }
}
