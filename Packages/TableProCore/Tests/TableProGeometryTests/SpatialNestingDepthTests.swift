import Foundation
@testable import TableProGeometry
import Testing

/// Every wire format lets a geometry collection nest without limit, and each level is one more frame
/// on the reader's stack, so a few hundred bytes of nothing but collection headers would exhaust it
/// rather than fail. Each reader refuses past `SpatialLimits.maximumNestingDepth`.
///
/// The limit counts the reader's own recursion, so a value whose innermost member is a point spends
/// one level on that point: the deepest value a reader accepts is `maximumNestingDepth - 1`
/// collections around it.
struct SpatialNestingDepthTests {
    @Test func testWKTAcceptsNestingUpToTheLimit() {
        let depth = SpatialLimits.maximumNestingDepth - 1
        #expect((try? WKTGeometryReader.read(Self.nestedWKT(depth: depth)).get()) != nil)
    }

    @Test func testWKTRefusesNestingPastTheLimit() {
        let text = Self.nestedWKT(depth: SpatialLimits.maximumNestingDepth)
        #expect(WKTGeometryReader.read(text) == .failure(.malformed))
    }

    /// The shape a crafted value takes: thousands of levels, and no stack to hold them.
    @Test func testWKTRefusesDeepNestingWithoutRecursingIntoIt() {
        let text = Self.nestedWKT(depth: 5_000)
        #expect(WKTGeometryReader.read(text) == .failure(.malformed))
    }

    @Test func testGeoJSONRefusesNestingPastTheLimit() {
        #expect(GeoJSONGeometryReader.read(Self.nestedGeoJSON(depth: 5_000)) == .failure(.notGeometry))
    }

    @Test func testGeoJSONAcceptsNestingUpToTheLimit() {
        let text = Self.nestedGeoJSON(depth: SpatialLimits.maximumNestingDepth - 1)
        #expect((try? GeoJSONGeometryReader.read(text).get()) != nil)
    }

    /// WKB nests the same way, a counted run of children each re-declaring its own byte order.
    @Test func testWKBRefusesNestingPastTheLimit() {
        var bytes: [UInt8] = []
        for _ in 0 ..< 5_000 {
            bytes += [0x01, 0x07, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00]
        }
        bytes += [0x01, 0x01, 0x00, 0x00, 0x00] + [UInt8](repeating: 0, count: 16)
        #expect(WKBGeometryReader.read(bytes: bytes) == .failure(.malformed))
    }

    /// A ClickHouse tuple nests by bracket alone, so 200 KB of brackets is all it takes. Far past
    /// the bound on purpose: a reader that recursed into this would overflow the stack.
    @Test func testTupleRefusesDeepNestingWithoutRecursingIntoIt() {
        for (open, close) in [("[", "]"), ("(", ")")] {
            let text = Self.nestedTuple(depth: 100_000, open: open, close: close)
            #expect(SpatialValueReader.readClickHouseTuple(text) == nil)
            #expect(SpatialValueReader.read(text) == .failure(.notGeometry))
        }
    }

    @Test func testTupleRefusesDeepNestingAroundAPoint() {
        let text = String(repeating: "[", count: 100_000) + "(1,2)" + String(repeating: "]", count: 100_000)
        #expect(SpatialValueReader.read(text) == .failure(.notGeometry))
    }

    /// The deepest value ClickHouse writes is a MultiPolygon, five levels with its numbers.
    @Test func testTupleStillReadsTheDeepestRealValue() {
        let text = "[[[(0,0),(1,0),(1,1),(0,0)],[(0.2,0.2),(0.4,0.2),(0.4,0.4),(0.2,0.2)]]]"
        guard case .multiPolygon(let polygons)? = SpatialValueReader.readClickHouseTuple(text)?.geometry else {
            Issue.record("expected a multipolygon")
            return
        }
        #expect(polygons.count == 1)
        #expect(polygons[0].count == 2)
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
