import XCTest
@testable import TableProGeometry

final class SpatialProjectionTests: XCTestCase {
    private let sanFrancisco = SpatialPoint(x: -122.4194, y: 37.7749)

    func testGeographicSRIDsDrawDirectly() {
        for srid: Int32 in [4326, 4269, 4979] {
            XCTAssertEqual(
                SpatialProjection.projectability(srid: srid, geometry: .point(sanFrancisco)),
                .geographic,
                "SRID \(srid) should draw directly"
            )
        }
    }

    func testWebMercatorAliases() {
        for srid: Int32 in [3857, 900_913, 102_100, 102_113, 3785] {
            XCTAssertEqual(
                SpatialProjection.projectability(srid: srid, geometry: .point(sanFrancisco)),
                .webMercator,
                "SRID \(srid) should invert as spherical Mercator"
            )
        }
    }

    /// Verified against PROJ 9.8.1 and re-derived independently: the closed form round-trips to
    /// zero error at double precision, so no projection library is needed for this family.
    func testWebMercatorInverseMatchesPROJ() {
        let projected = SpatialPoint(x: -13_627_665.271218073, y: 4_547_675.354340557)
        guard let coordinate = SpatialProjection.project(projected, using: .webMercator) else {
            return XCTFail("expected a coordinate")
        }
        XCTAssertEqual(coordinate.longitude, -122.4194, accuracy: 1e-9)
        XCTAssertEqual(coordinate.latitude, 37.7749, accuracy: 1e-9)
    }

    func testWebMercatorOriginIsNullIsland() {
        guard let coordinate = SpatialProjection.project(
            SpatialPoint(x: 0, y: 0),
            using: .webMercator
        ) else {
            return XCTFail("expected a coordinate")
        }
        XCTAssertEqual(coordinate.longitude, 0, accuracy: 1e-12)
        XCTAssertEqual(coordinate.latitude, 0, accuracy: 1e-12)
    }

    /// PostGIS writes no prefix for SRID 0 and MySQL stores a literal 0. Degrees are the common
    /// case for such a column, so values inside the envelope are drawn and the pane says so.
    func testAbsentSRIDInsideTheEnvelopeIsAssumedGeographic() {
        XCTAssertEqual(
            SpatialProjection.projectability(srid: nil, geometry: .point(sanFrancisco)),
            .assumedGeographic
        )
    }

    func testAbsentSRIDOutsideTheEnvelopeIsRefused() {
        let projectedMetres = SpatialPoint(x: -13_627_665.27, y: 4_547_675.35)
        XCTAssertEqual(
            SpatialProjection.projectability(srid: nil, geometry: .point(projectedMetres)),
            .unsupported(srid: nil)
        )
    }

    /// One coordinate outside the envelope disqualifies the whole geometry: half a shape drawn in
    /// the wrong place is worse than a shape reported as undrawable.
    func testOneStrayCoordinateDisqualifiesTheGeometry() {
        let ring = [
            SpatialPoint(x: 0, y: 0),
            SpatialPoint(x: 1, y: 1),
            SpatialPoint(x: 500_000, y: 1),
        ]
        XCTAssertEqual(
            SpatialProjection.projectability(srid: nil, geometry: .lineString(ring)),
            .unsupported(srid: nil)
        )
    }

    func testEmptyGeometryIsNotAssumedGeographic() {
        XCTAssertEqual(
            SpatialProjection.projectability(srid: nil, geometry: .empty),
            .unsupported(srid: nil)
        )
    }

    func testProjectedSRIDIsRefusedByNumber() {
        XCTAssertEqual(
            SpatialProjection.projectability(srid: 32_633, geometry: .point(sanFrancisco)),
            .unsupported(srid: 32_633)
        )
        XCTAssertNil(SpatialProjection.project(sanFrancisco, using: .unsupported(srid: 32_633)))
    }

    /// Outside the valid range `MKMapPoint(coordinate)` returns the sentinel (-1, -1) rather than
    /// wrapping, which is garbage outside `MKMapRectWorld` and destroys an extent fold. Nothing
    /// invalid may reach a shape.
    func testOutOfRangeCoordinatesAreRejectedBeforeAShapeIsBuilt() {
        XCTAssertNil(SpatialProjection.project(SpatialPoint(x: 180.0000001, y: 0), using: .geographic))
        XCTAssertNil(SpatialProjection.project(SpatialPoint(x: 0, y: 91), using: .geographic))
        XCTAssertNil(SpatialProjection.project(SpatialPoint(x: -181, y: 0), using: .geographic))
        XCTAssertNil(SpatialProjection.project(SpatialPoint(x: .nan, y: 0), using: .geographic))
        XCTAssertNil(SpatialProjection.project(SpatialPoint(x: .infinity, y: 0), using: .geographic))
    }

    func testExactEnvelopeEdgesAreValid() {
        XCTAssertNotNil(SpatialProjection.project(SpatialPoint(x: 180, y: 90), using: .geographic))
        XCTAssertNotNil(SpatialProjection.project(SpatialPoint(x: -180, y: -90), using: .geographic))
    }

    /// The stored order is (x, y) = (longitude, latitude) for every dialect the app reads.
    func testProjectionKeepsLongitudeInX() {
        guard let coordinate = SpatialProjection.project(sanFrancisco, using: .geographic) else {
            return XCTFail("expected a coordinate")
        }
        XCTAssertEqual(coordinate.longitude, -122.4194)
        XCTAssertEqual(coordinate.latitude, 37.7749)
    }
}
