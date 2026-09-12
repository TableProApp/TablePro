import XCTest
@testable import TableProGeometry

/// Every spelling here was produced by a live server in this repository's investigation of #2532:
/// PostGIS 3.6.4, MySQL 8.4.11, MariaDB 12.3.3 and DuckDB 1.5.4. They disagree with each other, so
/// the table is the specification.
final class WKTGeometryReaderTests: XCTestCase {
    private func value(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> SpatialValue? {
        switch WKTGeometryReader.read(text) {
        case .success(let value):
            return value
        case .failure(let failure):
            XCTFail("expected a geometry, got \(failure)", file: file, line: line)
            return nil
        }
    }

    private func failure(
        _ text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> SpatialReadFailure? {
        switch WKTGeometryReader.read(text) {
        case .success(let value):
            XCTFail("expected a failure, got \(value)", file: file, line: line)
            return nil
        case .failure(let failure):
            return failure
        }
    }

    func testPostGISEWKTCarriesItsSRID() {
        let parsed = value("SRID=4326;POINT(-122.4194 37.7749)")
        XCTAssertEqual(parsed?.srid, 4326)
        XCTAssertEqual(parsed?.geometry, .point(SpatialPoint(x: -122.4194, y: 37.7749)))
    }

    /// PostGIS writes the prefix only when the SRID is non-zero, so a bare geometry is the normal
    /// shape for an unconstrained column rather than a malformed one.
    func testBareWKTHasNoSRID() {
        let parsed = value("POINT(1 2)")
        XCTAssertNil(parsed?.srid)
        XCTAssertEqual(parsed?.geometry, .point(SpatialPoint(x: 1, y: 2)))
    }

    func testNegativeAndScientificOrdinates() {
        XCTAssertEqual(
            value("POINT(-1.5e2 +2.25)")?.geometry,
            .point(SpatialPoint(x: -150, y: 2.25))
        )
    }

    /// PostGIS writes XYZ with no tag at all, so the dimensionality is only visible in the count.
    func testBareThreeOrdinatesDropTheThird() {
        XCTAssertEqual(value("POINT(1 2 3)")?.geometry, .point(SpatialPoint(x: 1, y: 2)))
    }

    /// PostGIS writes XYM as POINTM, not as the OGC "POINT M (".
    func testPostGISPointM() {
        XCTAssertEqual(value("POINTM(1 2 3)")?.geometry, .point(SpatialPoint(x: 1, y: 2)))
    }

    func testOGCSeparatedDimensionTags() {
        XCTAssertEqual(value("POINT Z (1 2 3)")?.geometry, .point(SpatialPoint(x: 1, y: 2)))
        XCTAssertEqual(value("POINT ZM (1 2 3 4)")?.geometry, .point(SpatialPoint(x: 1, y: 2)))
        XCTAssertEqual(value("POINT M (1 2 3)")?.geometry, .point(SpatialPoint(x: 1, y: 2)))
    }

    func testFourOrdinates() {
        XCTAssertEqual(value("POINT(1 2 3 4)")?.geometry, .point(SpatialPoint(x: 1, y: 2)))
    }

    /// DuckDB 1.5.4 puts a space before the paren. Nothing else does.
    func testDuckDBSpaceBeforeParen() {
        XCTAssertEqual(value("POINT (1 2)")?.geometry, .point(SpatialPoint(x: 1, y: 2)))
        XCTAssertEqual(value("POINT Z (1 2 3)")?.geometry, .point(SpatialPoint(x: 1, y: 2)))
    }

    /// Both MULTIPOINT spellings are legal and both ship: PostGIS writes the bare form, MySQL the
    /// parenthesised one.
    func testBothMultiPointSpellings() {
        let expected = SpatialGeometry.multiPoint([SpatialPoint(x: 1, y: 2), SpatialPoint(x: 3, y: 4)])
        XCTAssertEqual(value("MULTIPOINT(1 2,3 4)")?.geometry, expected)
        XCTAssertEqual(value("MULTIPOINT((1 2),(3 4))")?.geometry, expected)
        XCTAssertEqual(value("MULTIPOINT (1 2, 3 4)")?.geometry, expected)
    }

    func testEmptyAtEveryLevel() {
        XCTAssertEqual(value("POINT EMPTY")?.geometry, .empty)
        XCTAssertEqual(value("GEOMETRYCOLLECTION EMPTY")?.geometry, .empty)
        XCTAssertEqual(value("POLYGON EMPTY")?.geometry, .empty)
        XCTAssertEqual(value("MULTIPOLYGON EMPTY")?.geometry, .empty)
    }

    /// MySQL 8.4 emits this for an empty collection. No grammar allows it, and it still has to read.
    func testMySQLInvalidEmptyCollection() {
        XCTAssertEqual(value("GEOMETRYCOLLECTION()")?.geometry, .empty)
    }

    /// MySQL 8.0.11 renamed the type; its catalog and its WKT both say GEOMCOLLECTION.
    func testMySQLGeomCollectionSpelling() {
        XCTAssertEqual(
            value("GEOMCOLLECTION(POINT(1 2))")?.geometry,
            .collection([.point(SpatialPoint(x: 1, y: 2))])
        )
    }

    func testPolygonWithHole() {
        let parsed = value("POLYGON((0 0,4 0,4 4,0 4,0 0),(1 1,2 1,2 2,1 2,1 1))")
        guard case .polygon(let rings)? = parsed?.geometry else {
            return XCTFail("expected a polygon")
        }
        XCTAssertEqual(rings.count, 2)
        XCTAssertEqual(rings[0].count, 5)
        XCTAssertEqual(rings[1].count, 5)
        XCTAssertEqual(rings[1][0], SpatialPoint(x: 1, y: 1))
    }

    func testMultiPolygon() {
        let parsed = value("MULTIPOLYGON(((0 0,1 0,1 1,0 0)),((5 5,6 5,6 6,5 5)))")
        guard case .multiPolygon(let polygons)? = parsed?.geometry else {
            return XCTFail("expected a multipolygon")
        }
        XCTAssertEqual(polygons.count, 2)
        XCTAssertEqual(polygons[1][0][0], SpatialPoint(x: 5, y: 5))
    }

    func testNestedCollection() {
        let parsed = value("GEOMETRYCOLLECTION(POINT(1 2),LINESTRING(3 4,5 6))")
        XCTAssertEqual(
            parsed?.geometry,
            .collection([
                .point(SpatialPoint(x: 1, y: 2)),
                .lineString([SpatialPoint(x: 3, y: 4), SpatialPoint(x: 5, y: 6)]),
            ])
        )
    }

    func testSRIDPrefixOnACollection() {
        XCTAssertEqual(value("SRID=3857;GEOMETRYCOLLECTION(POINT(1 2))")?.srid, 3857)
    }

    /// A curved or polyhedral type is named rather than dropped, because the pane has to say which
    /// keyword it refused.
    func testUnsupportedTypesAreNamed() {
        for keyword in [
            "CIRCULARSTRING", "COMPOUNDCURVE", "CURVEPOLYGON",
            "MULTICURVE", "MULTISURFACE", "POLYHEDRALSURFACE", "TIN", "TRIANGLE",
        ] {
            XCTAssertEqual(
                failure("\(keyword)(1 2,3 4,5 6)"),
                .unsupportedGeometryType(keyword),
                "expected \(keyword) to be refused by name"
            )
        }
    }

    func testOrdinaryTextIsNotAGeometry() {
        XCTAssertEqual(failure("hello world"), .notGeometry)
        XCTAssertEqual(failure(""), .notGeometry)
        XCTAssertEqual(failure("12345"), .notGeometry)
    }

    func testTruncatedInputIsMalformed() {
        XCTAssertEqual(failure("POINT(1 2"), .malformed)
        XCTAssertEqual(failure("POLYGON((0 0,1 1)"), .malformed)
        XCTAssertEqual(failure("POINT(1)"), .malformed)
    }

    func testTrailingTextIsRejected() {
        XCTAssertEqual(failure("POINT(1 2) extra"), .malformed)
    }

    func testLooksLikeWKTGatesTheSniffer() {
        XCTAssertTrue(WKTGeometryReader.looksLikeWKT("POINT(1 2)"))
        XCTAssertTrue(WKTGeometryReader.looksLikeWKT("SRID=4326;MULTIPOLYGON EMPTY"))
        XCTAssertTrue(WKTGeometryReader.looksLikeWKT("point (1 2)"))
        XCTAssertFalse(WKTGeometryReader.looksLikeWKT("hello"))
        XCTAssertFalse(WKTGeometryReader.looksLikeWKT("{\"type\":\"Point\"}"))
    }
}
