import XCTest
@testable import TableProTeradataCore

final class RecordDecoderDecimalTests: XCTestCase {
    func testDecimalByteWidthByPrecision() {
        XCTAssertEqual(RecordDecoder.decimalByteWidth(precision: 2), 1)
        XCTAssertEqual(RecordDecoder.decimalByteWidth(precision: 4), 2)
        XCTAssertEqual(RecordDecoder.decimalByteWidth(precision: 9), 4)
        XCTAssertEqual(RecordDecoder.decimalByteWidth(precision: 10), 8)
        XCTAssertEqual(RecordDecoder.decimalByteWidth(precision: 18), 8)
        XCTAssertEqual(RecordDecoder.decimalByteWidth(precision: 38), 16)
    }

    func testDecimalStringFormatsScaleAndSign() {
        XCTAssertEqual(RecordDecoder.decimalString([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x30, 0x39], scale: 2), "123.45")
        XCTAssertEqual(RecordDecoder.decimalString([0x00, 0x4B], scale: 1), "7.5")
        XCTAssertEqual(RecordDecoder.decimalString([0xFF, 0xFF, 0xCF, 0x2C], scale: 3), "-12.500")
        XCTAssertEqual(RecordDecoder.decimalString([0x00, 0x00], scale: 0), "0")
    }

    func testDecimalStringHandlesSixteenByteMagnitude() {
        var bytes = [UInt8](repeating: 0, count: 16)
        bytes[15] = 0x01
        XCTAssertEqual(RecordDecoder.decimalString(bytes, scale: 0), "1")
    }

    func testDecodeRecordWithDecimalColumn() throws {
        let columns = [
            ColumnMeta(typeCode: 496, dataLength: 4, name: "id"),
            ColumnMeta(typeCode: 485, dataLength: 0x0A02, name: "amount"),
        ]
        let bitmap: [UInt8] = [0x00]
        let idBytes: [UInt8] = [0x00, 0x00, 0x00, 0x07]
        let amountBytes: [UInt8] = [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x30, 0x39]
        let values = try RecordDecoder.decode(recordBody: bitmap + idBytes + amountBytes, columns: columns)
        XCTAssertEqual(values, [.integer(7), .text("123.45")])
    }
}
