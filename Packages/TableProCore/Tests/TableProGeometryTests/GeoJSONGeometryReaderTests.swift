@testable import TableProGeometry
import XCTest

/// RFC 7946 fixes the capitalisation of a type name. Elasticsearch documents its `geo_shape` types
/// in lowercase and hands a document back as it was indexed, so the reader takes any case.
final class GeoJSONGeometryReaderTests: XCTestCase {
    private func geometry(
        _ text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> SpatialGeometry? {
        switch GeoJSONGeometryReader.read(text) {
        case .success(let value):
            return value.geometry
        case .failure(let failure):
            XCTFail("expected a geometry, got \(failure) for \(text)", file: file, line: line)
            return nil
        }
    }

    func testPointReadsInAnyCase() {
        for type in ["Point", "point", "POINT", "pOiNt"] {
            XCTAssertEqual(
                geometry(#"{"type":"\#(type)","coordinates":[-73.97,40.77]}"#),
                .point(SpatialPoint(x: -73.97, y: 40.77))
            )
        }
    }

    func testPolygonReadsInAnyCase() {
        for type in ["Polygon", "polygon", "POLYGON"] {
            guard case .polygon(let rings)? = geometry(
                #"{"type":"\#(type)","coordinates":[[[0,0],[10,0],[10,10],[0,0]]]}"#
            ) else {
                return XCTFail("expected a polygon for \(type)")
            }
            XCTAssertEqual(rings.count, 1)
            XCTAssertEqual(rings[0].count, 4)
        }
    }

    func testEveryLowercaseTypeKeepsItsOwnShape() {
        let first = SpatialPoint(x: 0, y: 0)
        let second = SpatialPoint(x: 1, y: 1)
        XCTAssertEqual(
            geometry(#"{"type":"multipoint","coordinates":[[0,0],[1,1]]}"#),
            .multiPoint([first, second])
        )
        XCTAssertEqual(
            geometry(#"{"type":"linestring","coordinates":[[0,0],[1,1]]}"#),
            .lineString([first, second])
        )
        XCTAssertEqual(
            geometry(#"{"type":"multilinestring","coordinates":[[[0,0],[1,1]]]}"#),
            .multiLineString([[first, second]])
        )
        XCTAssertEqual(
            geometry(#"{"type":"multipolygon","coordinates":[[[[0,0],[1,1],[1,0],[0,0]]]]}"#),
            .multiPolygon([[[first, second, SpatialPoint(x: 1, y: 0), first]]])
        )
    }

    func testCollectionAndItsMembersReadInLowercase() {
        let json = #"{"type":"geometrycollection","geometries":[{"type":"point","coordinates":[1,2]},{"type":"LINESTRING","coordinates":[[3,4],[5,6]]}]}"#
        XCTAssertEqual(
            geometry(json),
            .collection([
                .point(SpatialPoint(x: 1, y: 2)),
                .lineString([SpatialPoint(x: 3, y: 4), SpatialPoint(x: 5, y: 6)]),
            ])
        )
    }

    func testFeatureWrappersReadInLowercase() {
        XCTAssertEqual(
            geometry(#"{"type":"feature","geometry":{"type":"point","coordinates":[1,2]},"properties":{}}"#),
            .point(SpatialPoint(x: 1, y: 2))
        )
        XCTAssertEqual(
            geometry(#"{"type":"FEATURECOLLECTION","features":[{"type":"FEATURE","geometry":{"type":"POINT","coordinates":[1,2]}}]}"#),
            .point(SpatialPoint(x: 1, y: 2))
        )
    }

    func testLowercaseTypeStillCarriesWGS84() {
        XCTAssertEqual(
            GeoJSONGeometryReader.read(#"{"type":"point","coordinates":[1,2]}"#),
            .success(SpatialValue(srid: 4_326, geometry: .point(SpatialPoint(x: 1, y: 2))))
        )
    }

    func testLowercaseTypeSurvivesTheSniff() {
        XCTAssertEqual(
            SpatialValueReader.read(#"{"type":"polygon","coordinates":[[[0,0],[10,0],[10,10],[0,0]]]}"#),
            GeoJSONGeometryReader.read(#"{"type":"Polygon","coordinates":[[[0,0],[10,0],[10,10],[0,0]]]}"#)
        )
    }

    /// Elasticsearch also writes `envelope` and `circle`, which have no GeoJSON shape. Folding case
    /// must not turn them, or any other name, into one that reads.
    func testNamesWithNoShapeStayRefused() {
        for json in [
            #"{"type":"envelope","coordinates":[[-10,10],[10,-10]]}"#,
            #"{"type":"circle","coordinates":[-10,10],"radius":"10m"}"#,
            #"{"type":"points","coordinates":[1,2]}"#,
            #"{"type":"","coordinates":[1,2]}"#,
        ] {
            XCTAssertEqual(GeoJSONGeometryReader.read(json), .failure(.notGeometry), json)
        }
    }
}
