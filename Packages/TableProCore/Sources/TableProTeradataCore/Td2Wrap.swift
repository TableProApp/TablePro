import Foundation

enum Td2Wrap {
    static let macLen = 32
    static let tagLen = 16

    private static func integerBytes(_ value: UInt64) -> [UInt8] {
        if value == 0 { return [0x00] }
        var v = value
        var bytes = [UInt8]()
        while v > 0 { bytes.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
        if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
        return bytes
    }

    private static func tlv(_ tag: UInt8, _ value: [UInt8]) -> [UInt8] {
        [tag] + Der.encodeLength(value.count) + value
    }

    static func wrap(plaintext: [UInt8], key: [UInt8], sequenceNumber: UInt64) throws -> [UInt8] {
        let plen = plaintext.count
        let msgLength = UInt64(plen + 48 + macLen)

        var nonce = [UInt8]()
        nonce.append(UInt8((msgLength >> 24) & 0xFF))
        nonce.append(UInt8((msgLength >> 16) & 0xFF))
        nonce.append(UInt8((msgLength >> 8) & 0xFF))
        nonce.append(UInt8(msgLength & 0xFF))
        for shift in stride(from: 56, through: 0, by: -8) {
            nonce.append(UInt8((sequenceNumber >> UInt64(shift)) & 0xFF))
        }

        let buffer = plaintext + nonce + [0, 0, 0, 0]
        let sealed = try GcmCipher(keyBytes: key).seal(buffer, nonce: nonce)
        let ciphertext = sealed.ciphertext
        let authTag = sealed.tag

        let tokenHeader =
            [0xC0, 0x01, 0x03]
            + [0xC1, 0x01, 0x07]
            + [0xC2, 0x01, 0x04]
            + [0xC3, 0x04, 0x00, 0x00, 0x00, 0x00]
            + tlv(0xC4, integerBytes(msgLength))
            + tlv(0xC5, integerBytes(sequenceNumber))

        let body = tlv(0xC0, ciphertext) + tlv(0xE1, tokenHeader) + tlv(0xC3, authTag)
        return tlv(0xE0, body)
    }

    static func unwrap(der: [UInt8], key: [UInt8]) throws -> [UInt8] {
        var reader = ByteReader(der)
        guard try reader.u8() == 0xE0 else { throw TeradataWireError.malformed("wrap: expected E0") }
        _ = try Der.decodeLength(&reader)

        var ciphertext: [UInt8] = []
        var authTag: [UInt8] = []
        var msgLength: UInt64 = 0
        var sequenceNumber: UInt64 = 0

        while reader.remaining > 0 {
            let tag = try reader.u8()
            let length = try Der.decodeLength(&reader)
            let value = try reader.take(length)
            switch tag {
            case 0xC0: ciphertext = value
            case 0xC3: authTag = value
            case 0xE1:
                var inner = ByteReader(value)
                while inner.remaining > 0 {
                    let innerTag = try inner.u8()
                    let innerLen = try Der.decodeLength(&inner)
                    let innerValue = try inner.take(innerLen)
                    if innerTag == 0xC4 { msgLength = beInteger(innerValue) }
                    if innerTag == 0xC5 { sequenceNumber = beInteger(innerValue) }
                }
            default: break
            }
        }

        guard !ciphertext.isEmpty, authTag.count == tagLen else {
            throw TeradataWireError.malformed("wrap: missing ciphertext/tag")
        }
        var nonce = [UInt8]()
        nonce.append(UInt8((msgLength >> 24) & 0xFF))
        nonce.append(UInt8((msgLength >> 16) & 0xFF))
        nonce.append(UInt8((msgLength >> 8) & 0xFF))
        nonce.append(UInt8(msgLength & 0xFF))
        for shift in stride(from: 56, through: 0, by: -8) {
            nonce.append(UInt8((sequenceNumber >> UInt64(shift)) & 0xFF))
        }
        let buffer = try GcmCipher(keyBytes: key).open(ciphertext: ciphertext, nonce: nonce, tag: authTag)
        guard buffer.count >= tagLen else { throw TeradataWireError.malformed("wrap: short plaintext") }
        return Array(buffer[0..<buffer.count - tagLen])
    }

    private static func beInteger(_ bytes: [UInt8]) -> UInt64 {
        var value: UInt64 = 0
        for byte in bytes { value = (value << 8) | UInt64(byte) }
        return value
    }

    static func encryptMessage(_ message: [UInt8], key: [UInt8], sequenceNumber: UInt64) throws -> [UInt8] {
        let clear = Array(message[0..<24])
        let plaintext = Array(message[24...])
        let der = try wrap(plaintext: plaintext, key: key, sequenceNumber: sequenceNumber)
        var out = clear + der
        let bodyLength = der.count - 28
        out[1] |= LanMessage.encryptedBodyFlag
        out[3] = UInt8((bodyLength >> 24) & 0xFF)
        out[4] = UInt8((bodyLength >> 16) & 0xFF)
        out[8] = UInt8((bodyLength >> 8) & 0xFF)
        out[9] = UInt8(bodyLength & 0xFF)
        return out
    }
}
