import XCTest
@testable import TableProGeometry

/// The sniffer is what makes a `.spatial` column work without the app knowing which engine it came
/// from. A PostGIS column reports `geometry` whether the value arrived as EWKT or, when the
/// `ST_AsEWKT` rewrite failed, as raw EWKB hex, so the value has to decide.
final class SpatialValueReaderTests: XCTestCase {
    private func geometry(
        _ text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> SpatialGeometry? {
        switch SpatialValueReader.read(text) {
        case .success(let value):
            return value.geometry
        case .failure(let failure):
            XCTFail("expected a geometry, got \(failure)", file: file, line: line)
            return nil
        }
    }

    func testEWKTIsRouted() {
        XCTAssertEqual(geometry("SRID=4326;POINT(-122.4194 37.7749)"),
                       .point(SpatialPoint(x: -122.4194, y: 37.7749)))
    }

    /// This is the PostGIS fallback path: the column still says `geometry` but the rewrite failed
    /// and the cell holds raw hex.
    func testEWKBHexIsRouted() {
        XCTAssertEqual(geometry("0101000020E610000050FC1873D79A5EC0D0D556EC2FE34240"),
                       .point(SpatialPoint(x: -122.4194, y: 37.7749)))
    }

    func testGeoJSONIsRouted() {
        XCTAssertEqual(
            geometry(#"{"type":"Point","coordinates":[-122.4194,37.7749]}"#),
            .point(SpatialPoint(x: -122.4194, y: 37.7749))
        )
    }

    func testGeoJSONCarriesWGS84() {
        guard case .success(let value) = SpatialValueReader.read(
            #"{"type":"Point","coordinates":[1,2]}"#
        ) else {
            return XCTFail("expected a geometry")
        }
        XCTAssertEqual(value.srid, 4326)
    }

    func testGeoJSONPolygonWithHole() {
        let json = #"{"type":"Polygon","coordinates":[[[0,0],[0,10],[10,10],[0,0]],[[2,2],[2,4],[4,4],[2,2]]]}"#
        guard case .polygon(let rings)? = geometry(json) else {
            return XCTFail("expected a polygon")
        }
        XCTAssertEqual(rings.count, 2)
    }

    func testGeoJSONFeatureUnwraps() {
        let json = #"{"type":"Feature","geometry":{"type":"Point","coordinates":[1,2]},"properties":{"a":1}}"#
        XCTAssertEqual(geometry(json), .point(SpatialPoint(x: 1, y: 2)))
    }

    /// A GeoJSON altitude is dropped, which is what `MKGeoJSONDecoder` does with the same input.
    func testGeoJSONThirdOrdinateIsDropped() {
        XCTAssertEqual(
            geometry(#"{"type":"Point","coordinates":[1,2,3]}"#),
            .point(SpatialPoint(x: 1, y: 2))
        )
    }

    /// ClickHouse streams TabSeparatedWithNamesAndTypes, so a Point is a bare tuple literal.
    func testClickHousePointTuple() {
        XCTAssertEqual(geometry("(-122.4194,37.7749)"),
                       .point(SpatialPoint(x: -122.4194, y: 37.7749)))
    }

    func testClickHouseRingBecomesAPolygon() {
        guard case .polygon(let rings)? = geometry("((0,0),(1,0),(1,1),(0,0))") else {
            return XCTFail("expected a polygon")
        }
        XCTAssertEqual(rings.count, 1)
        XCTAssertEqual(rings[0].count, 4)
    }

    func testClickHousePolygonWithHole() {
        guard case .polygon(let rings)? = geometry("(((0,0),(4,0),(4,4),(0,0)),((1,1),(2,1),(2,2),(1,1)))") else {
            return XCTFail("expected a polygon")
        }
        XCTAssertEqual(rings.count, 2)
    }

    /// Elasticsearch's `"lat,lon"` string is the one spelling in the whole reader that is
    /// latitude-first, and Elasticsearch documents it that way.
    func testElasticsearchLatLonStringIsLatitudeFirst() {
        XCTAssertEqual(
            geometry("37.7749,-122.4194"),
            .point(SpatialPoint(x: -122.4194, y: 37.7749))
        )
    }

    func testElasticsearchStringRejectsOutOfRangePairs() {
        XCTAssertNil(SpatialValueReader.readElasticsearchGeoPoint("200,100"))
        XCTAssertNil(SpatialValueReader.readElasticsearchGeoPoint("hello,world"))
        XCTAssertNil(SpatialValueReader.readElasticsearchGeoPoint("1,2,3"))
    }

    /// ClickHouse writes a `Tuple` in parentheses and an `Array` in square brackets, which is what
    /// `ClickHouseTabSeparatedRowDecoderTests` already pins for ordinary arrays. Requiring
    /// parentheses at every level rejected every `Ring`, `Polygon` and `MultiPolygon` the driver
    /// hands over.
    func testClickHouseRingUsesSquareBrackets() {
        guard case .polygon(let rings)? = geometry("[(0,0),(4,0),(4,4),(0,0)]") else {
            return XCTFail("expected a ring")
        }
        XCTAssertEqual(rings.count, 1)
        XCTAssertEqual(rings[0].count, 4)
        XCTAssertEqual(rings[0][1], SpatialPoint(x: 4, y: 0))
    }

    func testClickHousePolygonUsesSquareBracketsAtEveryLevel() {
        guard case .polygon(let rings)? = geometry("[[(0,0),(4,0),(4,4),(0,0)],[(1,1),(2,1),(2,2),(1,1)]]") else {
            return XCTFail("expected a polygon with a hole")
        }
        XCTAssertEqual(rings.count, 2)
    }

    func testClickHouseMultiPolygonUsesSquareBrackets() {
        let text = "[[[(0,0),(1,0),(1,1),(0,0)]],[[(5,5),(6,5),(6,6),(5,5)]]]"
        guard case .multiPolygon(let polygons)? = geometry(text) else {
            return XCTFail("expected a multipolygon")
        }
        XCTAssertEqual(polygons.count, 2)
    }

    /// Elasticsearch's object form is latitude-first, as Elasticsearch documents it, while its array
    /// form is longitude-first to match GeoJSON. Reading one as the other puts the point in the
    /// wrong hemisphere, so both are pinned.
    func testElasticsearchObjectFormIsLatitudeFirst() {
        XCTAssertEqual(
            geometry(#"{"lat":37.7749,"lon":-122.4194}"#),
            .point(SpatialPoint(x: -122.4194, y: 37.7749))
        )
        XCTAssertEqual(
            geometry(#"{"lat": 37.7749, "long": -122.4194}"#),
            .point(SpatialPoint(x: -122.4194, y: 37.7749))
        )
    }

    func testElasticsearchArrayFormIsLongitudeFirst() {
        XCTAssertEqual(
            geometry("[-122.4194,37.7749]"),
            .point(SpatialPoint(x: -122.4194, y: 37.7749))
        )
    }

    /// A geohash resolves to the centre of its cell, which is what Elasticsearch itself does.
    /// `9q8yyk8ytpxr` is San Francisco; twelve characters places it within a metre.
    func testElasticsearchGeohashResolvesToTheCellCentre() {
        guard case .point(let point)? = geometry("9q8yyk8ytpxr") else {
            return XCTFail("expected a point")
        }
        XCTAssertEqual(point.y, 37.7749, accuracy: 0.0001)
        XCTAssertEqual(point.x, -122.4194, accuracy: 0.0001)
    }

    func testElasticsearchGeohashRejectsLettersOutsideItsAlphabet() {
        XCTAssertNil(SpatialValueReader.readElasticsearchGeoPoint("aio1"))
        XCTAssertNil(SpatialValueReader.readElasticsearchGeoPoint("9q8yyk8ytpxr9q8yy"))
    }

    func testOrdinaryTextIsRefused() {
        XCTAssertEqual(SpatialValueReader.read("hello"), .failure(.notGeometry))
        XCTAssertEqual(SpatialValueReader.read("   "), .failure(.notGeometry))
        XCTAssertEqual(SpatialValueReader.read("2024-01-01"), .failure(.notGeometry))
    }

    /// A refused keyword keeps its name all the way through the sniffer, so the pane can print it.
    func testUnsupportedKeywordSurvivesTheSniff() {
        XCTAssertEqual(
            SpatialValueReader.read("CIRCULARSTRING(0 0,1 1,2 0)"),
            .failure(.unsupportedGeometryType("CIRCULARSTRING"))
        )
    }

    func testSurroundingWhitespaceIsIgnored() {
        XCTAssertEqual(geometry("  POINT(1 2)\n"), .point(SpatialPoint(x: 1, y: 2)))
    }
}
