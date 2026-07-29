import XCTest
@testable import TableProTeradataCore

final class LanMessageTests: XCTestCase {
    func testHeaderLayout() {
        let message = LanMessage(kind: .start, body: [0xAA, 0xBB], sessionNumber: 0x01020304,
                                 requestNumber: 0x11223344, hostCharSet: 0x7F)
        let encoded = message.encoded()
        XCTAssertEqual(encoded.count, LanMessage.headerLength + 2)
        XCTAssertEqual(encoded[0], 3)
        XCTAssertEqual(encoded[1], LanMessage.requestClass)
        XCTAssertEqual(encoded[2], MessageKind.start.rawValue)
        XCTAssertEqual(Array(encoded[20..<24]), [0x01, 0x02, 0x03, 0x04])
        XCTAssertEqual(Array(encoded[32..<36]), [0x11, 0x22, 0x33, 0x44])
        XCTAssertEqual(encoded[37], 0x7F)
        XCTAssertEqual(Array(encoded[52..<54]), [0xAA, 0xBB])
    }

    func testSplitBodyLength() {
        let body = [UInt8](repeating: 0x5A, count: 70000)
        let encoded = LanMessage(kind: .cont, body: body).encoded()
        let header = Array(encoded[0..<LanMessage.headerLength])
        XCTAssertEqual(LanMessage.bodyLength(fromHeader: header), 70000)
        XCTAssertEqual(UInt16(encoded[3]) << 8 | UInt16(encoded[4]), 0x0001)
        XCTAssertEqual(UInt16(encoded[8]) << 8 | UInt16(encoded[9]), 0x1170)
    }

    func testDecodeRoundTrip() {
        let original = LanMessage(kind: .connect, body: [1, 2, 3, 4, 5], sessionNumber: 42)
        let encoded = original.encoded()
        let header = Array(encoded[0..<LanMessage.headerLength])
        let bodyLength = LanMessage.bodyLength(fromHeader: header)
        let body = Array(encoded[LanMessage.headerLength..<LanMessage.headerLength + bodyLength])
        let decoded = LanMessage.decode(header: header, body: body)
        XCTAssertEqual(decoded.kind, MessageKind.connect.rawValue)
        XCTAssertEqual(decoded.sessionNumber, 42)
        XCTAssertEqual(decoded.body, [1, 2, 3, 4, 5])
        XCTAssertFalse(decoded.isBodyEncrypted)
    }

    func testEncryptedFlag() {
        let message = LanMessage(kind: .connect, body: [0], encrypted: true)
        let encoded = message.encoded()
        XCTAssertEqual(encoded[1] & LanMessage.encryptedBodyFlag, LanMessage.encryptedBodyFlag)
        let decoded = LanMessage.decode(header: Array(encoded[0..<52]), body: [0])
        XCTAssertTrue(decoded.isBodyEncrypted)
        XCTAssertEqual(decoded.trueClass, LanMessage.requestClass)
    }
}

final class ParcelTests: XCTestCase {
    func testStandardRoundTrip() throws {
        let parcels = [Parcel(.assign, body: [0x41, 0x42]), Parcel(.response, body: [0x00, 0x10])]
        let decoded = try Parcel.decodeAll(Parcel.encodeAll(parcels))
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].flavor, ParcelFlavor.assign.rawValue)
        XCTAssertEqual(decoded[0].body, [0x41, 0x42])
        XCTAssertEqual(decoded[1].knownFlavor, .response)
    }

    func testStandardHeaderBytes() {
        let encoded = Parcel(.logoff).encoded()
        XCTAssertEqual(encoded, [0x00, 0x25, 0x00, 0x04])
    }

    func testAlternateHeaderForLargeBody() throws {
        let body = [UInt8](repeating: 0x7E, count: 70000)
        let encoded = Parcel(.record, body: body).encoded()
        XCTAssertEqual(encoded[0] & 0x80, 0x80)
        XCTAssertEqual(UInt16(encoded[0]) << 8 | UInt16(encoded[1]),
                       ParcelFlavor.record.rawValue | Parcel.alternateFlag)
        let decoded = try Parcel.decodeAll(encoded)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].flavor, ParcelFlavor.record.rawValue)
        XCTAssertEqual(decoded[0].body.count, 70000)
    }
}

final class DerTests: XCTestCase {
    func testTd2MechanismOid() throws {
        let expected: [UInt8] = [0x06, 0x0D, 0x2B, 0x06, 0x01, 0x04, 0x01, 0x81, 0x3F,
                                 0x01, 0x87, 0x74, 0x01, 0x01, 0x09]
        let encoded = try Der.encodeObjectIdentifier("1.3.6.1.4.1.191.1.1012.1.1.9")
        XCTAssertEqual(encoded, expected)
        XCTAssertEqual(try Der.decodeObjectIdentifier(encoded), "1.3.6.1.4.1.191.1.1012.1.1.9")
    }

    func testLongLength() {
        XCTAssertEqual(Der.encodeLength(0x7F), [0x7F])
        XCTAssertEqual(Der.encodeLength(0x80), [0x81, 0x80])
        XCTAssertEqual(Der.encodeLength(300), [0x82, 0x01, 0x2C])
    }
}

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

final class DiffieHellmanTests: XCTestCase {
    private func primeBytes() -> [UInt8] { BigUInt(hex: DHVectors.primeHex)!.bytesBE() }

    func testSharedSecretMatches() {
        let dhA = DiffieHellman(primeBytes: primeBytes(), generatorBytes: [0x02],
                                privateExponentBytes: BigUInt(hex: "a1b2c3d4e5f6071829")!.bytesBE())
        let dhB = DiffieHellman(primeBytes: primeBytes(), generatorBytes: [0x02],
                                privateExponentBytes: BigUInt(hex: "0f1e2d3c4b5a69788796a5b4c3d2e1f0")!.bytesBE())
        let sharedA = dhA.sharedSecret(peerPublicKeyBytes: dhB.publicKeyBytes())
        let sharedB = dhB.sharedSecret(peerPublicKeyBytes: dhA.publicKeyBytes())
        XCTAssertEqual(sharedA, sharedB)
        XCTAssertEqual(dhA.publicKeyBytes().count, 256)
        XCTAssertEqual(sharedA.count, 256)
    }

    func testRandomExponentIsUnique() {
        let dh1 = DiffieHellman(primeBytes: primeBytes(), generatorBytes: [0x02])
        let dh2 = DiffieHellman(primeBytes: primeBytes(), generatorBytes: [0x02])
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

final class RecordDecoderTests: XCTestCase {
    func testNullBitmap() {
        XCTAssertEqual(RecordDecoder.nullBitmapLength(columnCount: 1), 1)
        XCTAssertEqual(RecordDecoder.nullBitmapLength(columnCount: 8), 1)
        XCTAssertEqual(RecordDecoder.nullBitmapLength(columnCount: 9), 2)
        XCTAssertTrue(RecordDecoder.isNull([0x20], column: 2))
        XCTAssertFalse(RecordDecoder.isNull([0x20], column: 0))
        XCTAssertTrue(RecordDecoder.isNull([0x80], column: 0))
    }

    func testDecodeMixedRow() throws {
        let columns = [
            ColumnMeta(typeCode: 497, dataLength: 4, name: "id"),
            ColumnMeta(typeCode: 449, dataLength: 10, name: "label"),
            ColumnMeta(typeCode: 497, dataLength: 4, name: "maybe"),
        ]
        let body: [UInt8] = [0x20]
            + [0x00, 0x00, 0x00, 0x01]
            + [0x00, 0x02, 0x68, 0x69]
            + [0x00, 0x00, 0x00, 0x00]
        let values = try RecordDecoder.decode(recordBody: body, columns: columns)
        XCTAssertEqual(values, [.integer(1), .text("hi"), .null])
    }

    func testDecodeNegativeAndChar() throws {
        let columns = [
            ColumnMeta(typeCode: 500, dataLength: 2, name: "n"),
            ColumnMeta(typeCode: 452, dataLength: 5, name: "code"),
        ]
        let body: [UInt8] = [0x00] + [0xFF, 0xFF] + Array("AB   ".utf8)
        let values = try RecordDecoder.decode(recordBody: body, columns: columns)
        XCTAssertEqual(values, [.integer(-1), .text("AB")])
    }
}
