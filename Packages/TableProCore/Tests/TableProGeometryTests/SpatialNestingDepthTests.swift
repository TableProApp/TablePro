@testable import TableProGeometry
import XCTest

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

    /// A ClickHouse tuple nests by bracket alone, so 200 KB of brackets is all it takes. Far past
    /// the bound on purpose: a reader that recursed into this would overflow the stack.
    func testTupleRefusesDeepNestingWithoutRecursingIntoIt() {
        for (open, close) in [("[", "]"), ("(", ")")] {
            let text = Self.nestedTuple(depth: 100_000, open: open, close: close)
            XCTAssertNil(SpatialValueReader.readClickHouseTuple(text))
            XCTAssertEqual(SpatialValueReader.read(text), .failure(.notGeometry))
        }
    }

    func testTupleRefusesDeepNestingAroundAPoint() {
        let text = String(repeating: "[", count: 100_000) + "(1,2)" + String(repeating: "]", count: 100_000)
        XCTAssertEqual(SpatialValueReader.read(text), .failure(.notGeometry))
    }

    /// The deepest value ClickHouse writes is a MultiPolygon, five levels with its numbers.
    func testTupleStillReadsTheDeepestRealValue() {
        let text = "[[[(0,0),(1,0),(1,1),(0,0)],[(0.2,0.2),(0.4,0.2),(0.4,0.4),(0.2,0.2)]]]"
        guard case .multiPolygon(let polygons)? = SpatialValueReader.readClickHouseTuple(text)?.geometry else {
            return XCTFail("expected a multipolygon")
        }
        XCTAssertEqual(polygons.count, 1)
        XCTAssertEqual(polygons[0].count, 2)
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

    private static func nestedTuple(depth: Int, open: String, close: String) -> String {
        String(repeating: open, count: depth) + String(repeating: close, count: depth)
    }
}
