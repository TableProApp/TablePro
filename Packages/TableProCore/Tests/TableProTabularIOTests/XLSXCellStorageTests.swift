import Foundation
@testable import TableProTabularIO
import XCTest

final class XLSXCellStorageTests: XCTestCase {
    func testChunkedArrayAddressesEveryElementAcrossBlocks() {
        var array = XLSXChunkedArray<UInt32>()
        XCTAssertTrue(array.isEmpty)
        for value in 0..<200_000 {
            array.append(UInt32(value * 2))
        }
        XCTAssertEqual(array.count, 200_000)
        XCTAssertEqual(array[0], 0)
        XCTAssertEqual(array[65_535], 131_070)
        XCTAssertEqual(array[65_536], 131_072)
        XCTAssertEqual(array[199_999], 399_998)
        XCTAssertEqual(array.lowerBound(of: 131_072), 65_536)
        XCTAssertEqual(array.lowerBound(of: 131_073), 65_537)
        XCTAssertEqual(array.lowerBound(of: 400_000), 200_000)
        array[70_000] = 7
        XCTAssertEqual(array[70_000], 7)
        XCTAssertEqual(array.firstIndex { $0 == 6 }, 3)
        XCTAssertEqual(array.firstIndex { $0 == 7 }, 70_000)
        XCTAssertEqual(array.lastIndex { $0 < 10 }, 70_000)
    }

    func testByteHeapReturnsEveryEntryIncludingOnesLargerThanABlock() throws {
        let builder = XLSXByteHeapBuilder()
        let small = Array("small".utf8)
        let large = [UInt8](repeating: 0x61, count: 3 << 20)
        let empty: [UInt8] = []
        let handles = [small, large, empty, small].map { entry in entry.withUnsafeBufferPointer { builder.append($0) } }
        let heap = builder.finish()
        XCTAssertEqual(Array(heap.bytes(at: handles[0])), small)
        XCTAssertEqual(Array(heap.bytes(at: handles[1])), large)
        XCTAssertTrue(heap.bytes(at: handles[2]).isEmpty)
        XCTAssertEqual(Array(heap.bytes(at: handles[3])), small)
        XCTAssertNotEqual(handles[1] >> 32, handles[0] >> 32)
    }

    func testDecimalTextRoundTripsThroughMantissaAndScale() {
        for text in ["0", "5", "-5", "0.05", "12.50", "-0.001", "999999999999999999", "123456.789"] {
            var copy = text
            let parsed = copy.withUTF8 { XLSXDecimal.parse($0) }
            guard let parsed else {
                XCTFail("\(text) should parse")
                continue
            }
            var output: [UInt8] = []
            XLSXDecimal.append(mantissa: parsed.mantissa, scale: parsed.scale, to: &output)
            XCTAssertEqual(String(bytes: output, encoding: .utf8), text)
        }
        for text in ["", "-", "-0", "007", ".5", "5.", "1e3", "1,5", "1234567890123456789", " 1"] {
            var copy = text
            XCTAssertNil(copy.withUTF8 { XLSXDecimal.parse($0) }, text)
        }
    }

    func testBuiltInNumberFormatsAreClassified() {
        XCTAssertEqual((14...17).map(XLSXNumberFormat.category(ofBuiltInFormat:)), [.date, .date, .date, .date])
        XCTAssertEqual((18...21).map(XLSXNumberFormat.category(ofBuiltInFormat:)), [.time, .time, .time, .time])
        XCTAssertEqual(XLSXNumberFormat.category(ofBuiltInFormat: 22), .date)
        XCTAssertEqual((45...47).map(XLSXNumberFormat.category(ofBuiltInFormat:)), [.time, .duration, .time])
        XCTAssertEqual([0, 1, 2, 3, 4, 9, 10, 11, 12, 13, 37, 44, 48, 49].map(XLSXNumberFormat.category(ofBuiltInFormat:)),
                       Array(repeating: .number, count: 14))
    }

    func testCustomFormatCodesAreClassifiedOutsideQuotesAndBrackets() {
        let expectations: [(String, XLSXNumberFormatCategory)] = [
            ("yyyy-mm-dd", .date),
            ("dd/mm/yyyy hh:mm", .date),
            ("mmm", .date),
            ("h:mm AM/PM", .time),
            ("mm:ss.0", .time),
            ("[h]:mm:ss", .duration),
            ("[mm]", .duration),
            ("yyyy [h]", .date),
            ("[$-409]mmmm d, yyyy;@", .date),
            ("0.00\" days\"", .number),
            ("#,##0 \"hrs\"", .number),
            ("[Red]0.00;[Blue]-0.00", .number),
            ("0.00E+00", .number),
            ("General", .number),
            ("@", .number),
            ("\\d0", .number),
            ("_(* #,##0_)", .number),
            ("*-0", .number)
        ]
        for (code, category) in expectations {
            XCTAssertEqual(XLSXNumberFormat.category(ofFormatCode: code), category, code)
        }
    }

    func testDateSystemsProduceISOText() {
        XCTAssertEqual(XLSXDateSystem.base1900.isoText(forSerial: 45_306), "2024-01-15")
        XCTAssertEqual(XLSXDateSystem.base1900.isoText(forSerial: 45_306.5), "2024-01-15 12:00:00")
        XCTAssertEqual(XLSXDateSystem.base1900.isoText(forSerial: 0.25, timeOnly: true), "06:00:00")
        XCTAssertEqual(XLSXDateSystem.base1900.isoText(forSerial: 0.000005787, timeOnly: true), "00:00:00.500")
        XCTAssertEqual(XLSXDateSystem.base1904.isoText(forSerial: 0), "1904-01-01")
        XCTAssertEqual(XLSXDateSystem.base1904.isoText(forSerial: 1_462), "1908-01-02")
        XCTAssertEqual(XLSXDateSystem.base1900.elapsedText(forSerial: 1.25), "30:00:00")
        XCTAssertEqual(XLSXDateSystem.base1904.elapsedText(forSerial: 0.5), "12:00:00")
        XCTAssertEqual(XLSXDateSystem.base1900.isoText(forSerial: .infinity), "")
        XCTAssertEqual(XLSXDateSystem.base1900.elapsedText(forSerial: 1e300), "")
        XCTAssertTrue(XLSXDateSystem.base1900.holds(serial: 2_958_465.9))
        XCTAssertFalse(XLSXDateSystem.base1900.holds(serial: 2_958_466))
        XCTAssertFalse(XLSXDateSystem.base1904.holds(serial: -1))
        XCTAssertFalse(XLSXDateSystem.base1900.holds(serial: .nan))
    }
}
