//
//  KdbxInnerStreamCipherTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("ChaCha20Cipher")
struct ChaCha20CipherTests {
    /// RFC 8439 A.1 Test Vector #1: key = 0, nonce = 0, counter starts at 0.
    @Test("RFC 8439 keystream block 0")
    func keystreamBlockZero() {
        var cipher = ChaCha20Cipher(key: [UInt8](repeating: 0, count: 32), nonce: [UInt8](repeating: 0, count: 12))
        let keystream = cipher.process([UInt8](repeating: 0, count: 64))

        let expected = hex("""
            76b8e0ada0f13d90405d6ae55386bd28bdd219b8a08ded1aa836efcc8b770dc7
            da41597c5157488d7724e03fb8d84a376a43b8f41518a11cc387b669b2ee6586
            """)
        #expect(keystream == expected)
    }

    /// RFC 8439 A.1 Test Vector #2: same key/nonce, counter 1 -> second block.
    @Test("RFC 8439 keystream blocks 0 and 1")
    func keystreamTwoBlocks() {
        var cipher = ChaCha20Cipher(key: [UInt8](repeating: 0, count: 32), nonce: [UInt8](repeating: 0, count: 12))
        let keystream = cipher.process([UInt8](repeating: 0, count: 128))

        let secondBlock = hex("""
            9f07e7be5551387a98ba977c732d080dcb0f29a048e3656912c6533e32ee7aed
            29b721769ce64e43d57133b074d839d531ed1f28510afb45ace10a1f4b794d6f
            """)
        #expect(Array(keystream[64..<128]) == secondBlock)
    }

    @Test("Process is XOR involution")
    func roundTrip() {
        let key = (0..<32).map { UInt8($0) }
        let nonce = (0..<12).map { UInt8($0) }
        let plaintext: [UInt8] = Array("the quick brown fox".utf8)

        var encryptCipher = ChaCha20Cipher(key: key, nonce: nonce)
        let ciphertext = encryptCipher.process(plaintext)

        var decryptCipher = ChaCha20Cipher(key: key, nonce: nonce)
        #expect(decryptCipher.process(ciphertext) == plaintext)
    }

    private func hex(_ string: String) -> [UInt8] {
        let cleaned = string.filter(\.isHexDigit)
        var bytes: [UInt8] = []
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            if let byte = UInt8(cleaned[index..<next], radix: 16) {
                bytes.append(byte)
            }
            index = next
        }
        return bytes
    }
}
