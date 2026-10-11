import Foundation
@testable import TableProPluginKit
@testable import TableProTabularIO
import XCTest

final class DelimitedParityTests: XCTestCase {
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            return value ^ (value >> 31)
        }
    }

    private let alphabet: [UInt8] = Array("ab,;\"\"\"\n\r\\ x|".utf8)

    func testRowIndexMatchesStreamingParserOnRandomInput() throws {
        var generator = SeededGenerator(state: 42)
        for trial in 0..<20_000 {
            let length = Int.random(in: 0...64, using: &generator)
            var bytes = (0..<length).map { _ in alphabet.randomElement(using: &generator) ?? 0x61 }
            let hasBOM = trial % 7 == 0
            if hasBOM {
                bytes = [0xEF, 0xBB, 0xBF] + bytes
            }
            let escape: UInt8 = trial.isMultiple(of: 2) ? 0x22 : 0x5C
            let delimiter: UInt8 = trial.isMultiple(of: 3) ? 0x3B : 0x2C
            var legacy = CSVDialect(delimiter: delimiter, hasBom: hasBOM)
            legacy.escapeChar = escape
            let dialect = DelimitedDialect(delimiter: delimiter, escape: escape, hasByteOrderMark: hasBOM)

            let expected = bytes.withUnsafeBufferPointer { CSVStreamingParser(dialect: legacy).indexRows($0) }
            let index = try bytes.withUnsafeBufferPointer {
                try DelimitedRowIndexer.index($0, dialect: dialect, contentStart: hasBOM ? 3 : 0)
            }
            let actual = (0..<index.rowCount).map { index.range(ofRow: $0) }
            XCTAssertEqual(actual, expected, "trial \(trial): \(TabularTextCodec.utf8String(bytes).debugDescription)")

            let expectedFields = bytes.withUnsafeBufferPointer { buffer in
                expected.map { CSVStreamingParser(dialect: legacy).parseRow(buffer, range: $0) }
            }
            let actualFields = bytes.withUnsafeBufferPointer { buffer -> [[String]] in
                guard let base = buffer.baseAddress else { return actual.map { _ in [""] } }
                return actual.map { DelimitedFieldReader(dialect: dialect).fields(in: base, range: $0) }
            }
            XCTAssertEqual(actualFields, expectedFields, "trial \(trial): \(TabularTextCodec.utf8String(bytes).debugDescription)")
        }
    }

    func testEndsWithLineTerminatorIsReported() throws {
        let withTerminator = Array("a,b\nc,d\n".utf8)
        let withoutTerminator = Array("a,b\nc,d".utf8)
        let dialect = DelimitedDialect()
        let first = try withTerminator.withUnsafeBufferPointer { try DelimitedRowIndexer.index($0, dialect: dialect, contentStart: 0) }
        let second = try withoutTerminator.withUnsafeBufferPointer { try DelimitedRowIndexer.index($0, dialect: dialect, contentStart: 0) }
        XCTAssertTrue(first.endsWithLineTerminator)
        XCTAssertFalse(second.endsWithLineTerminator)
        XCTAssertEqual(first.rowCount, 2)
        XCTAssertEqual(second.rowCount, 2)
    }

    func testIndexingStopsWhenCancelled() {
        let bytes = [UInt8](repeating: 0x61, count: (1 << 24) + 10)
        XCTAssertThrowsError(
            try bytes.withUnsafeBufferPointer {
                try DelimitedRowIndexer.index($0, dialect: DelimitedDialect(), contentStart: 0, isCancelled: { true })
            }
        ) { error in
            XCTAssertTrue(error is TabularCancellation)
        }
    }
}
