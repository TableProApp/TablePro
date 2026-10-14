import Foundation
import NIOCore
import OracleNIO
@testable import TableProOracleCore
import Testing

struct OracleBindValueTests {
    @Test func testEveryValueTakesItsPosition() {
        let bindings = OracleBindValue.bindings(for: [.text("a"), .bytes(Data([1, 2])), .null, .text(String(repeating: "x", count: 3_000))])
        #expect(bindings.count == 4)
    }

    /// A character can take more than four bytes, and a bind sized by characters was refused with
    /// ORA-01460 or ORA-01461 (measured on Oracle 23ai).
    @Test func testCharBindIsSizedInUTF8Bytes() {
        #expect(OracleCharBind(text: "👍🏽").size == 8)
        #expect(OracleCharBind(text: "🇻🇳").size == 8)
        #expect(OracleCharBind(text: "x\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}y").size == 27)
        #expect(OracleCharBind(text: "").size == 1)
    }

    @Test func testCharBindWritesItsOwnLength() {
        var short = ByteBuffer()
        OracleCharBind(text: "abc")._encodeRaw(into: &short, context: .default)
        #expect(Array(short.readableBytesView) == [3, 0x61, 0x62, 0x63])

        var long = ByteBuffer()
        OracleCharBind(text: String(repeating: "é", count: 1_000))._encodeRaw(into: &long, context: .default)
        #expect(long.getInteger(at: 0, as: UInt8.self) == 254)
    }

    /// Text up to a CHAR's 2,000 bytes binds as CHAR, so a `CHAR(10)` holding `abc` still matches it.
    @Test func testShortTextBindsAsChar() {
        #expect(OracleCharBind.defaultOracleType == .char)
        #expect(OracleBindValue.charByteLimit == 2_000)
    }
}
