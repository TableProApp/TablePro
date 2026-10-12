import TableProGeometry
import XCTest

/// Imported without `@testable`: the app reads `typeName` from another module, so this file stops
/// compiling if the accessor loses `public`.
final class SpatialGeometryTests: XCTestCase {
    private let point = SpatialPoint(x: 1, y: 2)

    func testTypeNameForEveryCase() {
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
            XCTAssertEqual(entry.geometry.typeName, entry.name)
        }
    }

    /// The name is the type the value declared, whatever is left inside it.
    func testTypeNameIgnoresContents() {
        XCTAssertEqual(SpatialGeometry.polygon(rings: []).typeName, "Polygon")
        XCTAssertEqual(SpatialGeometry.multiPoint([]).typeName, "MultiPoint")
        XCTAssertEqual(SpatialGeometry.collection([]).typeName, "GeometryCollection")
        XCTAssertEqual(SpatialGeometry.collection([.polygon(rings: [])]).typeName, "GeometryCollection")
    }

    func testTypeNameOfAReadValue() {
        XCTAssertEqual(
            try? WKTGeometryReader.read("MULTIPOLYGON(((0 0,1 0,1 1,0 0)))").get().geometry.typeName,
            "MultiPolygon"
        )
        XCTAssertEqual(try? WKTGeometryReader.read("POINT EMPTY").get().geometry.typeName, "Empty")
    }
}
