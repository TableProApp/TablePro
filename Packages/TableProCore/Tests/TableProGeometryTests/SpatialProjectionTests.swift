import Foundation
@testable import TableProGeometry
import Testing

struct SpatialProjectionTests {
    private let sanFrancisco = SpatialPoint(x: -122.4194, y: 37.7749)

    @Test func testGeographicSRIDsDrawDirectly() {
        for srid: Int32 in [4_326, 4_269, 4_979] {
            #expect(SpatialProjection.projectability(srid: srid, geometry: .point(sanFrancisco)) == .geographic, "SRID \(srid) should draw directly")
        }
    }

    /// ETRS89, GDA94, GDA2020, CGCS2000, SIRGAS 2000, NAD83(2011) and JGD2011: degrees on a datum
    /// within a few metres of WGS84, so they draw as they are stored.
    @Test func testRegionalGeographicDatumsDrawDirectly() {
        for srid: Int32 in [4_258, 4_283, 7_844, 4_490, 4_674, 6_318, 6_668] {
            #expect(SpatialProjection.projectability(srid: srid, geometry: .point(sanFrancisco)) == .geographic, "SRID \(srid) should draw directly")
        }
    }

    @Test func testRegionalGeographicDatumReadsThroughEWKT() {
        guard case .success(let value) = WKTGeometryReader.read("SRID=4258;POINT(10.5 52.3)") else {
            Issue.record("expected a geometry")
            return
        }
        let projectability = SpatialProjection.projectability(srid: value.srid, geometry: value.geometry)
        #expect(projectability == .geographic)
        #expect(SpatialProjection.project(SpatialPoint(x: 10.5, y: 52.3), using: projectability) == GeographicCoordinate(longitude: 10.5, latitude: 52.3))
    }

    @Test func testWebMercatorAliases() {
        for srid: Int32 in [3_857, 900_913, 102_100, 102_113, 3_785] {
            #expect(SpatialProjection.projectability(srid: srid, geometry: .point(sanFrancisco)) == .webMercator, "SRID \(srid) should invert as spherical Mercator")
        }
    }

    /// Verified against PROJ 9.8.1 and re-derived independently: the closed form round-trips to
    /// zero error at double precision, so no projection library is needed for this family.
    @Test func testWebMercatorInverseMatchesPROJ() {
        let projected = SpatialPoint(x: -13_627_665.271218073, y: 4_547_675.354340557)
        guard let coordinate = SpatialProjection.project(projected, using: .webMercator) else {
            Issue.record("expected a coordinate")
            return
        }
        #expect(abs(coordinate.longitude - (-122.4194)) <= 1e-9)
        #expect(abs(coordinate.latitude - (37.7749)) <= 1e-9)
    }

    @Test func testWebMercatorOriginIsNullIsland() {
        guard let coordinate = SpatialProjection.project(
            SpatialPoint(x: 0, y: 0),
            using: .webMercator
        ) else {
            Issue.record("expected a coordinate")
            return
        }
        #expect(abs(coordinate.longitude - (0)) <= 1e-12)
        #expect(abs(coordinate.latitude - (0)) <= 1e-12)
    }

    /// PostGIS writes no prefix for SRID 0 and MySQL stores a literal 0. Degrees are the common
    /// case for such a column, so values inside the envelope are drawn and the pane says so.
    @Test func testAbsentSRIDInsideTheEnvelopeIsAssumedGeographic() {
        #expect(SpatialProjection.projectability(srid: nil, geometry: .point(sanFrancisco)) == .assumedGeographic)
    }

    @Test func testAbsentSRIDOutsideTheEnvelopeIsRefused() {
        let projectedMetres = SpatialPoint(x: -13_627_665.27, y: 4_547_675.35)
        #expect(SpatialProjection.projectability(srid: nil, geometry: .point(projectedMetres)) == .unsupported(srid: nil))
    }

    /// One coordinate outside the envelope disqualifies the whole geometry: half a shape drawn in
    /// the wrong place is worse than a shape reported as undrawable.
    @Test func testOneStrayCoordinateDisqualifiesTheGeometry() {
        let ring = [
            SpatialPoint(x: 0, y: 0),
            SpatialPoint(x: 1, y: 1),
            SpatialPoint(x: 500_000, y: 1),
        ]
        #expect(SpatialProjection.projectability(srid: nil, geometry: .lineString(ring)) == .unsupported(srid: nil))
    }

    @Test func testEmptyGeometryIsNotAssumedGeographic() {
        #expect(SpatialProjection.projectability(srid: nil, geometry: .empty) == .unsupported(srid: nil))
    }

    @Test func testProjectedSRIDIsRefusedByNumber() {
        #expect(SpatialProjection.projectability(srid: 32_633, geometry: .point(sanFrancisco)) == .unsupported(srid: 32_633))
        #expect(SpatialProjection.project(sanFrancisco, using: .unsupported(srid: 32_633)) == nil)
    }

    /// Outside the valid range `MKMapPoint(coordinate)` returns the sentinel (-1, -1) rather than
    /// wrapping, which is garbage outside `MKMapRectWorld` and destroys an extent fold. Nothing
    /// invalid may reach a shape.
    @Test func testOutOfRangeCoordinatesAreRejectedBeforeAShapeIsBuilt() {
        #expect(SpatialProjection.project(SpatialPoint(x: 180.0000001, y: 0), using: .geographic) == nil)
        #expect(SpatialProjection.project(SpatialPoint(x: 0, y: 91), using: .geographic) == nil)
        #expect(SpatialProjection.project(SpatialPoint(x: -181, y: 0), using: .geographic) == nil)
        #expect(SpatialProjection.project(SpatialPoint(x: .nan, y: 0), using: .geographic) == nil)
        #expect(SpatialProjection.project(SpatialPoint(x: .infinity, y: 0), using: .geographic) == nil)
    }

    @Test func testExactEnvelopeEdgesAreValid() {
        #expect(SpatialProjection.project(SpatialPoint(x: 180, y: 90), using: .geographic) != nil)
        #expect(SpatialProjection.project(SpatialPoint(x: -180, y: -90), using: .geographic) != nil)
    }

    /// The stored order is (x, y) = (longitude, latitude) for every dialect the app reads.
    @Test func testProjectionKeepsLongitudeInX() {
        guard let coordinate = SpatialProjection.project(sanFrancisco, using: .geographic) else {
            Issue.record("expected a coordinate")
            return
        }
        #expect(coordinate.longitude == -122.4194)
        #expect(coordinate.latitude == 37.7749)
    }
}
