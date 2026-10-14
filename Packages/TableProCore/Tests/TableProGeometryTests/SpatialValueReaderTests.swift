import Foundation
@testable import TableProGeometry
import Testing

/// The sniffer is what makes a `.spatial` column work without the app knowing which engine it came
/// from. A PostGIS column reports `geometry` whether the value arrived as EWKT or, when the
/// `ST_AsEWKT` rewrite failed, as raw EWKB hex, so the value has to decide.
struct SpatialValueReaderTests {
    private func geometry(
        _ text: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) -> SpatialGeometry? {
        switch SpatialValueReader.read(text) {
        case .success(let value):
            return value.geometry
        case .failure(let failure):
            Issue.record("expected a geometry, got \(failure)", sourceLocation: sourceLocation)
            return nil
        }
    }

    @Test func testEWKTIsRouted() {
        #expect(geometry("SRID=4326;POINT(-122.4194 37.7749)") == .point(SpatialPoint(x: -122.4194, y: 37.7749)))
    }

    /// This is the PostGIS fallback path: the column still says `geometry` but the rewrite failed
    /// and the cell holds raw hex.
    @Test func testEWKBHexIsRouted() {
        #expect(geometry("0101000020E610000050FC1873D79A5EC0D0D556EC2FE34240") == .point(SpatialPoint(x: -122.4194, y: 37.7749)))
    }

    @Test func testGeoJSONIsRouted() {
        #expect(geometry(#"{"type":"Point","coordinates":[-122.4194,37.7749]}"#) == .point(SpatialPoint(x: -122.4194, y: 37.7749)))
    }

    @Test func testGeoJSONCarriesWGS84() {
        guard case .success(let value) = SpatialValueReader.read(
            #"{"type":"Point","coordinates":[1,2]}"#
        ) else {
            Issue.record("expected a geometry")
            return
        }
        #expect(value.srid == 4_326)
    }

    @Test func testGeoJSONPolygonWithHole() {
        let json = #"{"type":"Polygon","coordinates":[[[0,0],[0,10],[10,10],[0,0]],[[2,2],[2,4],[4,4],[2,2]]]}"#
        guard case .polygon(let rings)? = geometry(json) else {
            Issue.record("expected a polygon")
            return
        }
        #expect(rings.count == 2)
    }

    @Test func testGeoJSONFeatureUnwraps() {
        let json = #"{"type":"Feature","geometry":{"type":"Point","coordinates":[1,2]},"properties":{"a":1}}"#
        #expect(geometry(json) == .point(SpatialPoint(x: 1, y: 2)))
    }

    /// A GeoJSON altitude is dropped, which is what `MKGeoJSONDecoder` does with the same input.
    @Test func testGeoJSONThirdOrdinateIsDropped() {
        #expect(geometry(#"{"type":"Point","coordinates":[1,2,3]}"#) == .point(SpatialPoint(x: 1, y: 2)))
    }

    /// ClickHouse streams TabSeparatedWithNamesAndTypes, so a Point is a bare tuple literal.
    @Test func testClickHousePointTuple() {
        #expect(geometry("(-122.4194,37.7749)") == .point(SpatialPoint(x: -122.4194, y: 37.7749)))
    }

    @Test func testClickHouseRingBecomesAPolygon() {
        guard case .polygon(let rings)? = geometry("((0,0),(1,0),(1,1),(0,0))") else {
            Issue.record("expected a polygon")
            return
        }
        #expect(rings.count == 1)
        #expect(rings[0].count == 4)
    }

    @Test func testClickHousePolygonWithHole() {
        guard case .polygon(let rings)? = geometry("(((0,0),(4,0),(4,4),(0,0)),((1,1),(2,1),(2,2),(1,1)))") else {
            Issue.record("expected a polygon")
            return
        }
        #expect(rings.count == 2)
    }

    /// Elasticsearch's `"lat,lon"` string is the one spelling in the whole reader that is
    /// latitude-first, and Elasticsearch documents it that way.
    @Test func testElasticsearchLatLonStringIsLatitudeFirst() {
        #expect(geometry("37.7749,-122.4194") == .point(SpatialPoint(x: -122.4194, y: 37.7749)))
    }

    @Test func testElasticsearchStringRejectsOutOfRangePairs() {
        #expect(SpatialValueReader.readElasticsearchGeoPoint("200,100") == nil)
        #expect(SpatialValueReader.readElasticsearchGeoPoint("hello,world") == nil)
        #expect(SpatialValueReader.readElasticsearchGeoPoint("1,2,3") == nil)
    }

    /// ClickHouse writes a `Tuple` in parentheses and an `Array` in square brackets, which is what
    /// `ClickHouseTabSeparatedRowDecoderTests` already pins for ordinary arrays. Requiring
    /// parentheses at every level rejected every `Ring`, `Polygon` and `MultiPolygon` the driver
    /// hands over.
    @Test func testClickHouseRingUsesSquareBrackets() {
        guard case .polygon(let rings)? = geometry("[(0,0),(4,0),(4,4),(0,0)]") else {
            Issue.record("expected a ring")
            return
        }
        #expect(rings.count == 1)
        #expect(rings[0].count == 4)
        #expect(rings[0][1] == SpatialPoint(x: 4, y: 0))
    }

    @Test func testClickHousePolygonUsesSquareBracketsAtEveryLevel() {
        guard case .polygon(let rings)? = geometry("[[(0,0),(4,0),(4,4),(0,0)],[(1,1),(2,1),(2,2),(1,1)]]") else {
            Issue.record("expected a polygon with a hole")
            return
        }
        #expect(rings.count == 2)
    }

    @Test func testClickHouseMultiPolygonUsesSquareBrackets() {
        let text = "[[[(0,0),(1,0),(1,1),(0,0)]],[[(5,5),(6,5),(6,6),(5,5)]]]"
        guard case .multiPolygon(let polygons)? = geometry(text) else {
            Issue.record("expected a multipolygon")
            return
        }
        #expect(polygons.count == 2)
    }

    /// Elasticsearch's object form is latitude-first, as Elasticsearch documents it, while its array
    /// form is longitude-first to match GeoJSON. Reading one as the other puts the point in the
    /// wrong hemisphere, so both are pinned.
    @Test func testElasticsearchObjectFormIsLatitudeFirst() {
        #expect(geometry(#"{"lat":37.7749,"lon":-122.4194}"#) == .point(SpatialPoint(x: -122.4194, y: 37.7749)))
        #expect(geometry(#"{"lat": 37.7749, "long": -122.4194}"#) == .point(SpatialPoint(x: -122.4194, y: 37.7749)))
    }

    @Test func testElasticsearchArrayFormIsLongitudeFirst() {
        #expect(geometry("[-122.4194,37.7749]") == .point(SpatialPoint(x: -122.4194, y: 37.7749)))
    }

    /// A geohash resolves to the centre of its cell, which is what Elasticsearch itself does.
    /// `9q8yyk8ytpxr` is San Francisco; twelve characters places it within a metre.
    @Test func testElasticsearchGeohashResolvesToTheCellCentre() {
        guard case .point(let point)? = geometry("9q8yyk8ytpxr") else {
            Issue.record("expected a point")
            return
        }
        #expect(abs(point.y - (37.7749)) <= 0.0001)
        #expect(abs(point.x - (-122.4194)) <= 0.0001)
    }

    @Test func testElasticsearchGeohashRejectsLettersOutsideItsAlphabet() {
        #expect(SpatialValueReader.readElasticsearchGeoPoint("aio1") == nil)
        #expect(SpatialValueReader.readElasticsearchGeoPoint("9q8yyk8ytpxr9q8yy") == nil)
    }

    @Test func testOrdinaryTextIsRefused() {
        #expect(SpatialValueReader.read("hello") == .failure(.notGeometry))
        #expect(SpatialValueReader.read("   ") == .failure(.notGeometry))
        #expect(SpatialValueReader.read("2024-01-01") == .failure(.notGeometry))
    }

    /// A refused keyword keeps its name all the way through the sniffer, so the pane can print it.
    @Test func testUnsupportedKeywordSurvivesTheSniff() {
        #expect(SpatialValueReader.read("CIRCULARSTRING(0 0,1 1,2 0)") == .failure(.unsupportedGeometryType("CIRCULARSTRING")))
    }

    /// `CIRCULARSTRINGM` does not open like a type the WKT reader takes, so it reaches the last read
    /// by falling through every other reader, and has to come out named.
    @Test func testUnsupportedKeywordWithAFusedTagSurvivesTheSniff() {
        #expect(SpatialValueReader.read("CIRCULARSTRINGM(0 0 1,1 1 1,2 0 1)") == .failure(.unsupportedGeometryType("CIRCULARSTRING")))
        #expect(SpatialValueReader.read("SRID=4326;TINZM(((0 0 0 1,0 0 1 1,0 1 0 1,0 0 0 1)))") == .failure(.unsupportedGeometryType("TIN")))
    }

    @Test func testSurroundingWhitespaceIsIgnored() {
        #expect(geometry("  POINT(1 2)\n") == .point(SpatialPoint(x: 1, y: 2)))
    }
}
