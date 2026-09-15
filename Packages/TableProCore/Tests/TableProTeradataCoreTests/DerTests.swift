@testable import TableProTeradataCore
import XCTest

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
