@testable import TableProTeradataCore
import XCTest

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
