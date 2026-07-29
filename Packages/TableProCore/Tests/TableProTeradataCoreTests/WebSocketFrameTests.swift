import XCTest
@testable import TableProTeradataCore

final class WebSocketFrameTests: XCTestCase {
    func testAcceptKeyMatchesRFC6455Vector() {
        XCTAssertEqual(WebSocketFrame.acceptKey(for: "dGhlIHNhbXBsZSBub25jZQ=="), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }

    func testBinaryFramesAreUnmaskedWithFinBit() {
        let frame = WebSocketFrame.encodeBinary([0xAA, 0xBB, 0xCC])
        XCTAssertEqual(frame[0], 0x82)
        XCTAssertEqual(frame[1], 3)
        XCTAssertEqual(Array(frame[2...]), [0xAA, 0xBB, 0xCC])
    }

    func testExtendedLengthEncoding() {
        let payload = [UInt8](repeating: 0x5A, count: 300)
        let frame = WebSocketFrame.encodeBinary(payload)
        XCTAssertEqual(frame[0], 0x82)
        XCTAssertEqual(frame[1], 126)
        XCTAssertEqual(Int(frame[2]) << 8 | Int(frame[3]), 300)
        XCTAssertEqual(Array(frame[4...]), payload)
    }

    func testDecodeUnmaskedServerFrame() throws {
        var buffer: [UInt8] = [0x82, 0x03, 0x01, 0x02, 0x03, 0xFF]
        let frame = try WebSocketFrame.decode(&buffer)
        XCTAssertEqual(frame?.opcode, .binary)
        XCTAssertEqual(frame?.payload, [0x01, 0x02, 0x03])
        XCTAssertEqual(buffer, [0xFF])
    }

    func testDecodeMaskedFrameUnmasksPayload() throws {
        let mask: [UInt8] = [0x10, 0x20, 0x30, 0x40]
        let plain: [UInt8] = [0x41, 0x42, 0x43]
        var buffer: [UInt8] = [0x82, 0x83] + mask + plain.enumerated().map { $0.element ^ mask[$0.offset % 4] }
        let frame = try WebSocketFrame.decode(&buffer)
        XCTAssertEqual(frame?.payload, plain)
        XCTAssertTrue(buffer.isEmpty)
    }

    func testDecodeReturnsNilOnIncompleteFrame() throws {
        var buffer: [UInt8] = [0x82, 0x05, 0x01, 0x02]
        XCTAssertNil(try WebSocketFrame.decode(&buffer))
        XCTAssertEqual(buffer.count, 4)
    }
}
