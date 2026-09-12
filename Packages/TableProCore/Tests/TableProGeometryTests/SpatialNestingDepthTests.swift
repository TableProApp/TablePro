import XCTest
@testable import TableProGeometry

/// Every wire format lets a geometry collection nest without limit, and each level is one more frame
/// on the reader's stack, so a few hundred bytes of nothing but collection headers would exhaust it
/// rather than fail. Each reader refuses past `SpatialLimits.maximumNestingDepth`.
///
/// The limit counts the reader's own recursion, so a value whose innermost member is a point spends
/// one level on that point: the deepest value a reader accepts is `maximumNestingDepth - 1`
/// collections around it.
final class SpatialNestingDepthTests: XCTestCase {
    func testWKTAcceptsNestingUpToTheLimit() {
        let depth = SpatialLimits.maximumNestingDepth - 1
        XCTAssertNotNil(try? WKTGeometryReader.read(Self.nestedWKT(depth: depth)).get())
    }

    func testWKTRefusesNestingPastTheLimit() {
        let text = Self.nestedWKT(depth: SpatialLimits.maximumNestingDepth)
        XCTAssertEqual(WKTGeometryReader.read(text), .failure(.malformed))
    }

    /// The shape a crafted value takes: thousands of levels, and no stack to hold them.
    func testWKTRefusesDeepNestingWithoutRecursingIntoIt() {
        let text = Self.nestedWKT(depth: 5_000)
        XCTAssertEqual(WKTGeometryReader.read(text), .failure(.malformed))
    }

    func testGeoJSONRefusesNestingPastTheLimit() {
        XCTAssertEqual(
            GeoJSONGeometryReader.read(Self.nestedGeoJSON(depth: 5_000)),
            .failure(.notGeometry)
        )
    }

    func testGeoJSONAcceptsNestingUpToTheLimit() {
        let text = Self.nestedGeoJSON(depth: SpatialLimits.maximumNestingDepth - 1)
        XCTAssertNotNil(try? GeoJSONGeometryReader.read(text).get())
    }

    /// WKB nests the same way, a counted run of children each re-declaring its own byte order.
    func testWKBRefusesNestingPastTheLimit() {
        var bytes: [UInt8] = []
        for _ in 0 ..< 5_000 {
            bytes += [0x01, 0x07, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00]
        }
        bytes += [0x01, 0x01, 0x00, 0x00, 0x00] + [UInt8](repeating: 0, count: 16)
        XCTAssertEqual(WKBGeometryReader.read(bytes: bytes), .failure(.malformed))
    }

    private static func nestedWKT(depth: Int) -> String {
        String(repeating: "GEOMETRYCOLLECTION(", count: depth)
            + "POINT(1 2)"
            + String(repeating: ")", count: depth)
    }

    private static func nestedGeoJSON(depth: Int) -> String {
        String(repeating: #"{"type":"GeometryCollection","geometries":["#, count: depth)
            + #"{"type":"Point","coordinates":[1,2]}"#
            + String(repeating: "]}", count: depth)
    }
}
