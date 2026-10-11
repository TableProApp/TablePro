import NIOCore
import OracleNIO
@testable import TableProOracleCore
import XCTest

final class OracleBindValueTests: XCTestCase {
    func testEveryValueTakesItsPosition() {
        let bindings = OracleBindValue.bindings(for: [.text("a"), .bytes(Data([1, 2])), .null, .text(String(repeating: "x", count: 3_000))])
        XCTAssertEqual(bindings.count, 4)
    }

    /// A character can take more than four bytes, and a bind sized by characters was refused with
    /// ORA-01460 or ORA-01461 (measured on Oracle 23ai).
    func testCharBindIsSizedInUTF8Bytes() {
        XCTAssertEqual(OracleCharBind(text: "👍🏽").size, 8)
        XCTAssertEqual(OracleCharBind(text: "🇻🇳").size, 8)
        XCTAssertEqual(OracleCharBind(text: "x\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}y").size, 27)
        XCTAssertEqual(OracleCharBind(text: "").size, 1)
    }

    func testCharBindWritesItsOwnLength() {
        var short = ByteBuffer()
        OracleCharBind(text: "abc")._encodeRaw(into: &short, context: .default)
        XCTAssertEqual(Array(short.readableBytesView), [3, 0x61, 0x62, 0x63])

        var long = ByteBuffer()
        OracleCharBind(text: String(repeating: "é", count: 1_000))._encodeRaw(into: &long, context: .default)
        XCTAssertEqual(long.getInteger(at: 0, as: UInt8.self), 254)
    }

    /// Text up to a CHAR's 2,000 bytes binds as CHAR, so a `CHAR(10)` holding `abc` still matches it.
    func testShortTextBindsAsChar() {
        XCTAssertEqual(OracleCharBind.defaultOracleType, .char)
        XCTAssertEqual(OracleBindValue.charByteLimit, 2_000)
    }
}
