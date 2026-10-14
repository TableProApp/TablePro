import Foundation
@testable import TableProGeometry
import Testing

/// RFC 7946 fixes the capitalisation of a type name. Elasticsearch documents its `geo_shape` types
/// in lowercase and hands a document back as it was indexed, so the reader takes any case.
struct GeoJSONGeometryReaderTests {
    private func geometry(
        _ text: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) -> SpatialGeometry? {
        switch GeoJSONGeometryReader.read(text) {
        case .success(let value):
            return value.geometry
        case .failure(let failure):
            Issue.record("expected a geometry, got \(failure) for \(text)", sourceLocation: sourceLocation)
            return nil
        }
    }

    @Test func testPointReadsInAnyCase() {
        for type in ["Point", "point", "POINT", "pOiNt"] {
            #expect(geometry(#"{"type":"\#(type)","coordinates":[-73.97,40.77]}"#) == .point(SpatialPoint(x: -73.97, y: 40.77)))
        }
    }

    @Test func testPolygonReadsInAnyCase() {
        for type in ["Polygon", "polygon", "POLYGON"] {
            guard case .polygon(let rings)? = geometry(
                #"{"type":"\#(type)","coordinates":[[[0,0],[10,0],[10,10],[0,0]]]}"#
            ) else {
                Issue.record("expected a polygon for \(type)")
                return
            }
            #expect(rings.count == 1)
            #expect(rings[0].count == 4)
        }
    }

    @Test func testEveryLowercaseTypeKeepsItsOwnShape() {
        let first = SpatialPoint(x: 0, y: 0)
        let second = SpatialPoint(x: 1, y: 1)
        #expect(geometry(#"{"type":"multipoint","coordinates":[[0,0],[1,1]]}"#) == .multiPoint([first, second]))
        #expect(geometry(#"{"type":"linestring","coordinates":[[0,0],[1,1]]}"#) == .lineString([first, second]))
        #expect(geometry(#"{"type":"multilinestring","coordinates":[[[0,0],[1,1]]]}"#) == .multiLineString([[first, second]]))
        #expect(geometry(#"{"type":"multipolygon","coordinates":[[[[0,0],[1,1],[1,0],[0,0]]]]}"#) == .multiPolygon([[[first, second, SpatialPoint(x: 1, y: 0), first]]]))
    }

    @Test func testCollectionAndItsMembersReadInLowercase() {
        let json = #"{"type":"geometrycollection","geometries":[{"type":"point","coordinates":[1,2]},{"type":"LINESTRING","coordinates":[[3,4],[5,6]]}]}"#
        #expect(geometry(json) == .collection([
            .point(SpatialPoint(x: 1, y: 2)),
            .lineString([SpatialPoint(x: 3, y: 4), SpatialPoint(x: 5, y: 6)]),
        ]))
    }

    @Test func testFeatureWrappersReadInLowercase() {
        #expect(geometry(#"{"type":"feature","geometry":{"type":"point","coordinates":[1,2]},"properties":{}}"#) == .point(SpatialPoint(x: 1, y: 2)))
        #expect(geometry(#"{"type":"FEATURECOLLECTION","features":[{"type":"FEATURE","geometry":{"type":"POINT","coordinates":[1,2]}}]}"#) == .point(SpatialPoint(x: 1, y: 2)))
    }

    @Test func testLowercaseTypeStillCarriesWGS84() {
        #expect(GeoJSONGeometryReader.read(#"{"type":"point","coordinates":[1,2]}"#) == .success(SpatialValue(srid: 4_326, geometry: .point(SpatialPoint(x: 1, y: 2)))))
    }

    @Test func testLowercaseTypeSurvivesTheSniff() {
        let lowercase = SpatialValueReader.read(#"{"type":"polygon","coordinates":[[[0,0],[10,0],[10,10],[0,0]]]}"#)
        #expect(lowercase == GeoJSONGeometryReader.read(#"{"type":"Polygon","coordinates":[[[0,0],[10,0],[10,10],[0,0]]]}"#))
    }

    /// Elasticsearch also writes `envelope` and `circle`, which have no GeoJSON shape. Folding case
    /// must not turn them, or any other name, into one that reads.
    @Test func testNamesWithNoShapeStayRefused() {
        for json in [
            #"{"type":"envelope","coordinates":[[-10,10],[10,-10]]}"#,
            #"{"type":"circle","coordinates":[-10,10],"radius":"10m"}"#,
            #"{"type":"points","coordinates":[1,2]}"#,
            #"{"type":"","coordinates":[1,2]}"#,
        ] {
            #expect(GeoJSONGeometryReader.read(json) == .failure(.notGeometry), "\(json)")
        }
    }
}
