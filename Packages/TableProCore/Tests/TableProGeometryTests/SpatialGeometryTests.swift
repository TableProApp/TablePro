import Foundation
import TableProGeometry
import Testing

/// Imported without `@testable`: the app reads `typeName` from another module, so this file stops
/// compiling if the accessor loses `public`.
struct SpatialGeometryTests {
    private let point = SpatialPoint(x: 1, y: 2)

    @Test func testTypeNameForEveryCase() {
        let ring = [point, SpatialPoint(x: 3, y: 4), SpatialPoint(x: 5, y: 0), point]
        let expected: [(geometry: SpatialGeometry, name: String)] = [
            (.point(point), "Point"),
            (.lineString([point, SpatialPoint(x: 3, y: 4)]), "LineString"),
            (.polygon(rings: [ring]), "Polygon"),
            (.multiPoint([point]), "MultiPoint"),
            (.multiLineString([[point, SpatialPoint(x: 3, y: 4)]]), "MultiLineString"),
            (.multiPolygon([[ring]]), "MultiPolygon"),
            (.collection([.point(point)]), "GeometryCollection"),
            (.empty, "Empty"),
        ]
        for entry in expected {
            #expect(entry.geometry.typeName == entry.name)
        }
    }

    /// The name is the type the value declared, whatever is left inside it.
    @Test func testTypeNameIgnoresContents() {
        #expect(SpatialGeometry.polygon(rings: []).typeName == "Polygon")
        #expect(SpatialGeometry.multiPoint([]).typeName == "MultiPoint")
        #expect(SpatialGeometry.collection([]).typeName == "GeometryCollection")
        #expect(SpatialGeometry.collection([.polygon(rings: [])]).typeName == "GeometryCollection")
    }

    @Test func testTypeNameOfAReadValue() {
        #expect((try? WKTGeometryReader.read("MULTIPOLYGON(((0 0,1 0,1 1,0 0)))").get().geometry.typeName) == "MultiPolygon")
        #expect((try? WKTGeometryReader.read("POINT EMPTY").get().geometry.typeName) == "Empty")
    }
}
