@testable import TableProTeradataCore
import XCTest

final class ParcelTests: XCTestCase {
    func testStandardRoundTrip() throws {
        let parcels = [Parcel(.assign, body: [0x41, 0x42]), Parcel(.response, body: [0x00, 0x10])]
        let decoded = try Parcel.decodeAll(Parcel.encodeAll(parcels))
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].flavor, ParcelFlavor.assign.rawValue)
        XCTAssertEqual(decoded[0].body, [0x41, 0x42])
        XCTAssertEqual(decoded[1].knownFlavor, .response)
    }

    func testStandardHeaderBytes() {
        let encoded = Parcel(.logoff).encoded()
        XCTAssertEqual(encoded, [0x00, 0x25, 0x00, 0x04])
    }

    func testAlternateHeaderForLargeBody() throws {
        let body = [UInt8](repeating: 0x7E, count: 70_000)
        let encoded = Parcel(.record, body: body).encoded()
        XCTAssertEqual(encoded[0] & 0x80, 0x80)
        XCTAssertEqual(UInt16(encoded[0]) << 8 | UInt16(encoded[1]),
                       ParcelFlavor.record.rawValue | Parcel.alternateFlag)
        let decoded = try Parcel.decodeAll(encoded)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].flavor, ParcelFlavor.record.rawValue)
        XCTAssertEqual(decoded[0].body.count, 70_000)
    }
}
