@testable import TableProTeradataCore
import XCTest

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
        let body = [UInt8](repeating: 0x5A, count: 70_000)
        let encoded = LanMessage(kind: .cont, body: body).encoded()
        let header = Array(encoded[0..<LanMessage.headerLength])
        XCTAssertEqual(LanMessage.bodyLength(fromHeader: header), 70_000)
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
