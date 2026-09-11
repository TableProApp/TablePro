//
//  GeometryWKBParserTests.swift
//  TableProTests
//
//  Tests for GeometryWKBParser WKB-to-WKT conversion
//

import Foundation
import TableProPluginKit
import Testing

// MARK: - Test Helpers

/// Builds MySQL internal geometry binary: 4-byte SRID (LE) + WKB payload.
private func mysqlGeometry(srid: UInt32 = 0, wkb: [UInt8]) -> Data {
    var data = Data()
    var s = srid.littleEndian
    data.append(Data(bytes: &s, count: 4))
    data.append(contentsOf: wkb)
    return data
}

/// Builds a little-endian WKB header: byte order (0x01) + type code (LE UInt32).
private func wkbHeader(type: UInt32) -> [UInt8] {
    var bytes: [UInt8] = [0x01] // little-endian
    let t = type.littleEndian
    bytes.append(contentsOf: withUnsafeBytes(of: t) { Array($0) })
    return bytes
}

/// Encodes a Float64 as little-endian bytes.
private func float64Bytes(_ value: Double) -> [UInt8] {
    let bits = value.bitPattern.littleEndian
    return withUnsafeBytes(of: bits) { Array($0) }
}

/// Encodes a UInt32 as little-endian bytes.
private func uint32Bytes(_ value: UInt32) -> [UInt8] {
    let v = value.littleEndian
    return withUnsafeBytes(of: v) { Array($0) }
}

/// Builds a WKB point (no header) — just two Float64 coordinate values.
private func pointCoords(_ x: Double, _ y: Double) -> [UInt8] {
    float64Bytes(x) + float64Bytes(y)
}

/// Builds a complete WKB Point geometry (with header).
private func wkbPoint(_ x: Double, _ y: Double) -> [UInt8] {
    wkbHeader(type: 1) + pointCoords(x, y)
}

/// Builds a complete WKB LineString geometry (with header).
private func wkbLineString(_ points: [(Double, Double)]) -> [UInt8] {
    var bytes = wkbHeader(type: 2)
    bytes += uint32Bytes(UInt32(points.count))
    for (x, y) in points {
        bytes += pointCoords(x, y)
    }
    return bytes
}

/// Builds a complete WKB Polygon geometry (with header).
private func wkbPolygon(_ rings: [[(Double, Double)]]) -> [UInt8] {
    var bytes = wkbHeader(type: 3)
    bytes += uint32Bytes(UInt32(rings.count))
    for ring in rings {
        bytes += uint32Bytes(UInt32(ring.count))
        for (x, y) in ring {
            bytes += pointCoords(x, y)
        }
    }
    return bytes
}

// MARK: - Tests

@Suite("GeometryWKBParser")
struct GeometryWKBParserTests {
    @Test("Point: little-endian binary produces WKT")
    func testPoint() {
        let data = mysqlGeometry(wkb: wkbPoint(1.0, 2.0))
        let result = GeometryWKBParser.parse(data)
        #expect(result == "POINT(1.0 2.0)")
    }

    @Test("LineString: 2 points produce WKT")
    func testLineString() {
        let data = mysqlGeometry(wkb: wkbLineString([(0, 0), (1, 1)]))
        let result = GeometryWKBParser.parse(data)
        #expect(result == "LINESTRING(0.0 0.0, 1.0 1.0)")
    }

    @Test("Polygon: 1 ring with 4 points produces WKT")
    func testPolygon() {
        let ring: [(Double, Double)] = [(0, 0), (10, 0), (10, 10), (0, 0)]
        let data = mysqlGeometry(wkb: wkbPolygon([ring]))
        let result = GeometryWKBParser.parse(data)
        #expect(result == "POLYGON((0.0 0.0, 10.0 0.0, 10.0 10.0, 0.0 0.0))")
    }

    @Test("MultiPoint: 2 points produce WKT")
    func testMultiPoint() {
        var wkb = wkbHeader(type: 4)
        wkb += uint32Bytes(2)
        wkb += wkbPoint(1, 2)
        wkb += wkbPoint(3, 4)
        let data = mysqlGeometry(wkb: wkb)
        let result = GeometryWKBParser.parse(data)
        #expect(result == "MULTIPOINT(1.0 2.0, 3.0 4.0)")
    }

    @Test("MultiLineString: 2 line strings produce WKT")
    func testMultiLineString() {
        var wkb = wkbHeader(type: 5)
        wkb += uint32Bytes(2)
        wkb += wkbLineString([(0, 0), (1, 1)])
        wkb += wkbLineString([(2, 2), (3, 3)])
        let data = mysqlGeometry(wkb: wkb)
        let result = GeometryWKBParser.parse(data)
        #expect(result == "MULTILINESTRING((0.0 0.0, 1.0 1.0), (2.0 2.0, 3.0 3.0))")
    }

    @Test("MultiPolygon: 2 polygons produce WKT")
    func testMultiPolygon() {
        let ring1: [(Double, Double)] = [(0, 0), (1, 0), (1, 1), (0, 0)]
        let ring2: [(Double, Double)] = [(2, 2), (3, 2), (3, 3), (2, 2)]
        var wkb = wkbHeader(type: 6)
        wkb += uint32Bytes(2)
        wkb += wkbPolygon([ring1])
        wkb += wkbPolygon([ring2])
        let data = mysqlGeometry(wkb: wkb)
        let result = GeometryWKBParser.parse(data)
        #expect(result == "MULTIPOLYGON(((0.0 0.0, 1.0 0.0, 1.0 1.0, 0.0 0.0)), ((2.0 2.0, 3.0 2.0, 3.0 3.0, 2.0 2.0)))")
    }

    @Test("GeometryCollection: nested types produce WKT")
    func testGeometryCollection() {
        var wkb = wkbHeader(type: 7)
        wkb += uint32Bytes(2)
        wkb += wkbPoint(1, 2)
        wkb += wkbLineString([(3, 4), (5, 6)])
        let data = mysqlGeometry(wkb: wkb)
        let result = GeometryWKBParser.parse(data)
        #expect(result == "GEOMETRYCOLLECTION(POINT(1.0 2.0), LINESTRING(3.0 4.0, 5.0 6.0))")
    }

    @Test("hexString: short data falls back to hex representation")
    func testShortDataFallsBackToHex() {
        // Less than 9 bytes — too short to be valid geometry
        let data = Data([0x00, 0x01, 0x02, 0x03])
        let result = GeometryWKBParser.parse(data)
        #expect(result == "0x00010203")
    }

    @Test("hexString: valid geometry data returns WKT string")
    func testValidGeometryReturnsWKT() {
        let data = mysqlGeometry(wkb: wkbPoint(42.5, -73.25))
        let result = GeometryWKBParser.parse(data)
        #expect(result == "POINT(42.5 -73.25)")
        // Confirm it does NOT start with "0x"
        #expect(!result.hasPrefix("0x"))
    }

    @Test("hexString: empty data returns empty string")
    func testEmptyData() {
        let result = GeometryWKBParser.hexString(Data())
        #expect(result == "")
    }

    @Test("formatCoord: whole numbers produce .1f format")
    func testFormatCoordWholeNumbers() {
        // Whole number coordinates should display as "1.0" not "1"
        let data = mysqlGeometry(wkb: wkbPoint(100, 200))
        let result = GeometryWKBParser.parse(data)
        #expect(result == "POINT(100.0 200.0)")
    }
}
