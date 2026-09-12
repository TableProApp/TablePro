import XCTest
@testable import TableProGeometry

/// Every hex fixture here came off a live server during the investigation of #2532. The PostGIS
/// ones are the wire bytes libpq hands over before the `ST_AsEWKT` rewrite runs; the MySQL and
/// MariaDB ones are what `libmariadb` returns for a geometry column.
final class WKBGeometryReaderTests: XCTestCase {
    private func value(
        hex: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> SpatialValue? {
        switch WKBGeometryReader.read(hex: hex) {
        case .success(let value):
            return value
        case .failure(let failure):
            XCTFail("expected a geometry, got \(failure)", file: file, line: line)
            return nil
        }
    }

    /// **The MySQL orientation guard.**
    ///
    /// Measured byte-identical on MySQL 8.4.11 and MariaDB 12.3.3 for a SRID-4326 point at San
    /// Francisco. MySQL's `ST_AsText` prints this value latitude-first, so the plausible-looking
    /// "make the parser agree with ST_AsText" change would swap these two numbers and move every
    /// MySQL point into the Southern Ocean. The storage is longitude-first and this test says so.
    func testMySQLInternalIsLongitudeFirst() {
        let hex = "E6100000010100000050FC1873D79A5EC0D0D556EC2FE34240"
        guard let bytes = Self.bytes(hex) else { return XCTFail("bad fixture") }
        guard case .success(let parsed) = WKBGeometryReader.read(mysqlInternal: bytes) else {
            return XCTFail("expected a geometry")
        }
        XCTAssertEqual(parsed.srid, 4326)
        guard case .point(let point) = parsed.geometry else { return XCTFail("expected a point") }
        XCTAssertEqual(point.x, -122.4194, accuracy: 1e-9, "x must be LONGITUDE")
        XCTAssertEqual(point.y, 37.7749, accuracy: 1e-9, "y must be LATITUDE")
    }

    /// MySQL writes a literal 0 for "no SRID", which means unknown rather than a system numbered 0.
    func testMySQLInternalZeroSRIDReadsAsAbsent() {
        let hex = "00000000010100000050FC1873D79A5EC0D0D556EC2FE34240"
        guard let bytes = Self.bytes(hex) else { return XCTFail("bad fixture") }
        guard case .success(let parsed) = WKBGeometryReader.read(mysqlInternal: bytes) else {
            return XCTFail("expected a geometry")
        }
        XCTAssertNil(parsed.srid)
    }

    func testPostGISEWKBSRIDFlag() {
        let parsed = value(hex: "0101000020E610000050FC1873D79A5EC0D0D556EC2FE34240")
        XCTAssertEqual(parsed?.srid, 4326)
        guard case .point(let point)? = parsed?.geometry else { return XCTFail("expected a point") }
        XCTAssertEqual(point.x, -122.4194, accuracy: 1e-9)
    }

    func testPlainWKBWithoutSRID() {
        let parsed = value(hex: "0101000000000000000000F03F0000000000000040")
        XCTAssertNil(parsed?.srid)
        XCTAssertEqual(parsed?.geometry, .point(SpatialPoint(x: 1, y: 2)))
    }

    func testBigEndianByteOrder() {
        let parsed = value(hex: "00000000013FF00000000000004000000000000000")
        XCTAssertEqual(parsed?.geometry, .point(SpatialPoint(x: 1, y: 2)))
    }

    /// `POINT EMPTY` has no zero-length body in the format; every producer writes two NaN doubles.
    func testNaNPointReadsAsEmpty() {
        let parsed = value(hex: "0101000000000000000000F87F000000000000F87F")
        XCTAssertEqual(parsed?.geometry, .empty)
    }

    /// ISO WKB adds 1000/2000/3000 to the type for Z, M and ZM; PostGIS EWKB sets high bits. Both
    /// dialects reach the app from the same column.
    func testISOAndEWKBDimensionEncodings() {
        XCTAssertEqual(
            value(hex: "01E9030000000000000000F03F00000000000000400000000000000840")?.geometry,
            .point(SpatialPoint(x: 1, y: 2))
        )
        XCTAssertEqual(
            value(hex: "0101000080000000000000F03F00000000000000400000000000000840")?.geometry,
            .point(SpatialPoint(x: 1, y: 2))
        )
        XCTAssertEqual(
            value(hex: "0101000040000000000000F03F00000000000000400000000000000840")?.geometry,
            .point(SpatialPoint(x: 1, y: 2))
        )
    }

    /// Verbatim from MySQL 8.4.11:
    /// `HEX(ST_GeomFromText('POLYGON((0 0,4 0,4 4,0 4,0 0),(1 1,2 1,2 2,1 2,1 1))',0))`.
    /// It carries the 4-byte SRID prefix, so it reads through the MySQL entry point.
    func testPolygonWithInteriorRing() {
        let hex = "00000000010300000002000000050000000000000000000000000000000000000000000000"
            + "0000104000000000000000000000000000001040000000000000104000000000000000000000"
            + "0000000010400000000000000000000000000000000005000000000000000000F03F00000000"
            + "0000F03F0000000000000040000000000000F03F000000000000004000000000000000400000"
            + "00000000F03F0000000000000040000000000000F03F000000000000F03F"
        guard let bytes = Self.bytes(hex) else { return XCTFail("bad fixture") }
        guard case .success(let parsed) = WKBGeometryReader.read(mysqlInternal: bytes) else {
            return XCTFail("expected a geometry")
        }
        guard case .polygon(let rings) = parsed.geometry else {
            return XCTFail("expected a polygon")
        }
        XCTAssertEqual(rings.count, 2)
        XCTAssertEqual(rings[0].count, 5)
        XCTAssertEqual(rings[1][0], SpatialPoint(x: 1, y: 1))
    }

    /// A nested geometry re-declares its own byte order. A reader that inherits the parent's is
    /// correct only by luck on the mixed-endian values some producers write.
    ///
    /// Verbatim from MySQL 8.4.11:
    /// `HEX(ST_GeomFromText('GEOMETRYCOLLECTION(POINT(1 2),LINESTRING(3 4,5 6))',0))`.
    func testCollectionMembersDeclareTheirOwnByteOrder() {
        let hex = "000000000107000000020000000101000000000000000000F03F000000000000004001020000"
            + "00020000000000000000000840000000000000104000000000000014400000000000001840"
        guard let bytes = Self.bytes(hex) else { return XCTFail("bad fixture") }
        guard case .success(let parsed) = WKBGeometryReader.read(mysqlInternal: bytes) else {
            return XCTFail("expected a geometry")
        }
        guard case .collection(let children) = parsed.geometry else {
            return XCTFail("expected a collection")
        }
        XCTAssertEqual(children.count, 2)
        XCTAssertEqual(children[0], .point(SpatialPoint(x: 1, y: 2)))
        XCTAssertEqual(
            children[1],
            .lineString([SpatialPoint(x: 3, y: 4), SpatialPoint(x: 5, y: 6)])
        )
    }

    func testTruncatedBufferIsMalformedRatherThanACrash() {
        XCTAssertEqual(WKBGeometryReader.read(hex: "0101000000000000000000F03F"), .failure(.malformed))
        XCTAssertEqual(WKBGeometryReader.read(hex: "0101"), .failure(.malformed))
    }

    /// A declared count far larger than the bytes remaining must be refused before it is used to
    /// reserve capacity.
    func testAbsurdPointCountIsRefused() {
        XCTAssertEqual(
            WKBGeometryReader.read(hex: "0102000000FFFFFF7F0000000000000000"),
            .failure(.malformed)
        )
    }

    func testCurvedTypesAreNamed() {
        XCTAssertEqual(
            WKBGeometryReader.read(hex: "010800000000000000"),
            .failure(.unsupportedGeometryType("CIRCULARSTRING"))
        )
        XCTAssertEqual(
            WKBGeometryReader.read(hex: "011000000000000000"),
            .failure(.unsupportedGeometryType("TIN"))
        )
    }

    func testNonHexIsNotAGeometry() {
        XCTAssertEqual(WKBGeometryReader.read(hex: "not hex at all"), .failure(.notGeometry))
        XCTAssertEqual(WKBGeometryReader.read(hex: "0101000"), .failure(.notGeometry))
    }

    func testLooksLikeHexGatesTheSniffer() {
        XCTAssertTrue(WKBGeometryReader.looksLikeHex("0101000020E6100000"))
        XCTAssertFalse(WKBGeometryReader.looksLikeHex("POINT(1 2)"))
        XCTAssertFalse(WKBGeometryReader.looksLikeHex("DEADBE"))
        XCTAssertFalse(WKBGeometryReader.looksLikeHex("0101000020E610000"))
    }

    private static func bytes(_ hex: String) -> [UInt8]? {
        var out: [UInt8] = []
        var high: UInt8?
        for character in hex.utf8 {
            let nibble: UInt8
            switch character {
            case 0x30 ... 0x39: nibble = character - 0x30
            case 0x41 ... 0x46: nibble = character - 0x41 + 10
            case 0x61 ... 0x66: nibble = character - 0x61 + 10
            default: return nil
            }
            if let pending = high {
                out.append(pending << 4 | nibble)
                high = nil
            } else {
                high = nibble
            }
        }
        return high == nil ? out : nil
    }
}
