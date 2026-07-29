import CryptoKit
import Foundation

struct GcmCipher {
    static let nonceLength = 12
    static let tagLength = 16

    let key: SymmetricKey

    init(keyBytes: [UInt8]) {
        key = SymmetricKey(data: Data(keyBytes))
    }

    func seal(_ plaintext: [UInt8], nonce nonceBytes: [UInt8], aad: [UInt8] = []) throws -> (ciphertext: [UInt8], tag: [UInt8]) {
        guard nonceBytes.count == GcmCipher.nonceLength else {
            throw TeradataWireError.malformed("GCM nonce must be \(GcmCipher.nonceLength) bytes")
        }
        let nonce = try AES.GCM.Nonce(data: Data(nonceBytes))
        let sealed = try AES.GCM.seal(Data(plaintext), using: key, nonce: nonce, authenticating: Data(aad))
        return (Array(sealed.ciphertext), Array(sealed.tag))
    }

    func open(ciphertext: [UInt8], nonce nonceBytes: [UInt8], tag: [UInt8], aad: [UInt8] = []) throws -> [UInt8] {
        guard nonceBytes.count == GcmCipher.nonceLength else {
            throw TeradataWireError.malformed("GCM nonce must be \(GcmCipher.nonceLength) bytes")
        }
        guard tag.count == GcmCipher.tagLength else {
            throw TeradataWireError.malformed("GCM tag must be \(GcmCipher.tagLength) bytes")
        }
        let box = try AES.GCM.SealedBox(
            nonce: try AES.GCM.Nonce(data: Data(nonceBytes)),
            ciphertext: Data(ciphertext),
            tag: Data(tag))
        return Array(try AES.GCM.open(box, using: key, authenticating: Data(aad)))
    }
}
