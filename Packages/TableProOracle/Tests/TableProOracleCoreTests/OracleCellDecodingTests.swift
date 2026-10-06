import NIOCore
import OracleNIO
@testable import TableProOracleCore
import XCTest

/// Cells built from wire bytes measured on Oracle 23ai, decoded the way a result decodes them.
final class OracleCellDecodingTests: XCTestCase {
    private static let utcPlusSeven = OracleSessionTimeZones(
        database: .gmt,
        session: TimeZone(secondsFromGMT: 7 * 3_600) ?? .gmt
    )

    private func decode(
        _ bytes: [UInt8]?,
        as type: OracleDataType,
        declared: OracleDataType? = nil,
        scale: Int = 0
    ) -> (OracleRawCell, Set<String>) {
        let cell = OracleCell(bytes: bytes.map { ByteBuffer(bytes: $0) }, dataType: type, columnName: "C", columnIndex: 0)
        let column = OracleResultColumn(name: "C", dataType: declared ?? type, scale: scale)
        var unsupported: Set<String> = []
        let value = OracleCellDecoding.decode(cell, column: column, zones: Self.utcPlusSeven) { unsupported.insert($0) }
        return (value, unsupported)
    }

    private static func hex(_ text: String) -> [UInt8] {
        var bytes: [UInt8] = []
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            bytes.append(UInt8(text[index ..< next], radix: 16) ?? 0)
            index = next
        }
        return bytes
    }

    /// Every NCHAR value used to read `<decode error>`.
    func testNCharDecodesAsText() {
        let (value, _) = decode(Self.hex("006800e9006c006c006f0020"), as: .nChar)
        XCTAssertEqual(value, .string("héllo "))
    }

    /// Every native JSON value used to read `<decode error>`.
    func testJSONDecodesAsTextInStoredOrder() {
        let oson = Self.hex(
            "ff4a5a01612605000a0030000b2c5273ade500020004000800060000016201610163017a0164840305010200110014"
                + "002606000031323021c102c0050011002000240010000e22c10333017884020403002e000f0179"
        )
        let (value, _) = decode(oson, as: .json)
        XCTAssertEqual(value, .string(#"{"b":1,"a":[1,2.5,"x",null,true],"c":{"z":"y","d":false}}"#))
    }

    /// A NUMBER past 19 digits trapped the integer decode and crashed the app; past 15 the text was a
    /// rounded Double in exponent notation.
    func testNumberKeepsEveryDigit() {
        XCTAssertEqual(decode(Self.hex("cc0d23394f5b0d23394f5b0d23"), as: .number).0, .string("123456789012345678901234"))
        XCTAssertEqual(decode(Self.hex("4559432d170b59432d1766"), as: .number).0, .string("-0.000000000000123456789012345678"))
        XCTAssertEqual(decode(Self.hex("c902182e445a02182e441a"), as: .number).0, .string("12345678901234567.25"))
        XCTAssertEqual(decode(Self.hex("c102"), as: .number).0, .string("1"))
    }

    /// A negative INTERVAL DAY TO SECOND trapped in the driver's decode and crashed the app.
    func testNegativeIntervalDecodes() {
        XCTAssertEqual(decode(Self.hex("7fffffff3a393862329b00"), as: .intervalDS).0, .string("-1 02:03:04.5"))
    }

    func testDatetimesUseTheColumnsScale() {
        XCTAssertEqual(decode(Self.hex("787e0a06101715"), as: .date).0, .string("2026-10-06 15:22:20"))
        XCTAssertEqual(decode(Self.hex("787c010204050602faf080"), as: .timestamp, scale: 6).0, .string("2024-01-02 03:04:05.050000"))
        XCTAssertEqual(decode(Self.hex("787c0102040506"), as: .timestamp, scale: 0).0, .string("2024-01-02 03:04:05"))
        XCTAssertEqual(
            decode(Self.hex("787c0102092306075bca000f1e"), as: .timestampTZ, scale: 6).0,
            .string("2024-01-02 03:04:05.123456-05:30")
        )
        XCTAssertEqual(
            decode(Self.hex("787c0102020506000003e8"), as: .timestampLTZ, scale: 6).0,
            .string("2024-01-02 08:04:05.000001+07:00")
        )
    }

    func testUniversalRowIDReadsAsOracleSpellsIt() {
        XCTAssertEqual(decode(Array("*BAYAAesCwQL+".utf8), as: .uRowID).0, .string("*BAYAAesCwQL+"))
    }

    func testRefIsAPlaceholderThatIsReported() {
        let (value, unsupported) = decode(Self.hex("002202085d2faade1176048de063020011acd7a1"), as: .ref)
        XCTAssertEqual(value, .string("<unsupported: ref>"))
        XCTAssertEqual(unsupported, ["ref"])
    }

    func testBFILENamesItsFile() {
        let locator = Self.hex("00240001080800000001000090000000000d444154415f50554d505f4449520005782e62696e")
        XCTAssertEqual(decode(locator, as: .bFile).0, .string("BFILENAME('DATA_PUMP_DIR', 'x.bin')"))
    }

    /// A BLOB arrives as LONG RAW, which is still bytes.
    func testBLOBFetchedAsLongRawIsBytes() {
        XCTAssertEqual(decode([0xde, 0xad], as: .longRAW, declared: .blob).0, .bytes(Data([0xde, 0xad])))
    }

    func testMissingBytesAreNull() {
        XCTAssertEqual(decode(nil, as: .varchar).0, .null)
    }
}
