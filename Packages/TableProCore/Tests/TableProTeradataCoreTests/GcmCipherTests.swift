@testable import TableProTeradataCore
import XCTest

final class GcmCipherTests: XCTestCase {
    private let key = [UInt8](repeating: 0x2B, count: 16)
    private let nonce = [UInt8](repeating: 0x11, count: 12)

    func testRoundTrip() throws {
        let cipher = GcmCipher(keyBytes: key)
        let plaintext: [UInt8] = Array("username,password,account".utf8)
        let sealed = try cipher.seal(plaintext, nonce: nonce, aad: [0x01, 0x02])
        let opened = try cipher.open(ciphertext: sealed.ciphertext, nonce: nonce, tag: sealed.tag, aad: [0x01, 0x02])
        XCTAssertEqual(opened, plaintext)
        XCTAssertEqual(sealed.tag.count, GcmCipher.tagLength)
    }

    func testTamperRejected() throws {
        let cipher = GcmCipher(keyBytes: key)
        var sealed = try cipher.seal([0xDE, 0xAD, 0xBE, 0xEF], nonce: nonce)
        sealed.ciphertext[0] ^= 0xFF
        XCTAssertThrowsError(try cipher.open(ciphertext: sealed.ciphertext, nonce: nonce, tag: sealed.tag))
    }
}
