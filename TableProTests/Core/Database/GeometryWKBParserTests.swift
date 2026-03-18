//
//  GeometryWKBParserTests.swift
//  TableProTests
//
//  Tests for GeometryWKBParser WKB-to-WKT conversion
//

import Foundation
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

// MARK: - Local Copy of GeometryWKBParser

// Copied from Plugins/MySQLDriverPlugin/GeometryWKBParser.swift
// because the plugin is a bundle target and cannot be imported with @testable import.

private enum GeometryWKBParser {
    static func parse(_ data: Data) -> String {
        guard data.count >= 9 else {
            return hexString(data)
        }

        let wkbData = data.dropFirst(4)
        var offset = wkbData.startIndex
        return parseWKBGeometry(wkbData, offset: &offset) ?? hexString(data)
    }

    static func parse(_ buffer: UnsafeRawBufferPointer) -> String {
        let data = Data(buffer)
        return parse(data)
    }

    private static func parseWKBGeometry(_ data: Data.SubSequence, offset: inout Data.Index) -> String? {
        guard offset < data.endIndex else { return nil }

        let byteOrder = data[offset]
        let littleEndian = byteOrder == 0x01
        offset = data.index(after: offset)

        guard let typeCode = readUInt32(data, offset: &offset, littleEndian: littleEndian) else {
            return nil
        }

        switch typeCode {
        case 1:
            return parsePoint(data, offset: &offset, littleEndian: littleEndian)
        case 2:
            return parseLineString(data, offset: &offset, littleEndian: littleEndian)
        case 3:
            return parsePolygon(data, offset: &offset, littleEndian: littleEndian)
        case 4:
            return parseMultiPoint(data, offset: &offset, littleEndian: littleEndian)
        case 5:
            return parseMultiLineString(data, offset: &offset, littleEndian: littleEndian)
        case 6:
            return parseMultiPolygon(data, offset: &offset, littleEndian: littleEndian)
        case 7:
            return parseGeometryCollection(data, offset: &offset, littleEndian: littleEndian)
        default:
            return nil
        }
    }

    private static func parsePoint(
        _ data: Data.SubSequence,
        offset: inout Data.Index,
        littleEndian: Bool
    ) -> String? {
        guard let x = readFloat64(data, offset: &offset, littleEndian: littleEndian),
              let y = readFloat64(data, offset: &offset, littleEndian: littleEndian) else {
            return nil
        }
        return "POINT(\(formatCoord(x)) \(formatCoord(y)))"
    }

    private static func parseLineString(
        _ data: Data.SubSequence,
        offset: inout Data.Index,
        littleEndian: Bool
    ) -> String? {
        guard let points = readPointList(data, offset: &offset, littleEndian: littleEndian) else {
            return nil
        }
        return "LINESTRING(\(points))"
    }

    private static func parsePolygon(
        _ data: Data.SubSequence,
        offset: inout Data.Index,
        littleEndian: Bool
    ) -> String? {
        guard let numRings = readUInt32(data, offset: &offset, littleEndian: littleEndian) else {
            return nil
        }
        var rings: [String] = []
        for _ in 0 ..< numRings {
            guard let points = readPointList(data, offset: &offset, littleEndian: littleEndian) else {
                return nil
            }
            rings.append("(\(points))")
        }
        return "POLYGON(\(rings.joined(separator: ", ")))"
    }

    private static func parseMultiPoint(
        _ data: Data.SubSequence,
        offset: inout Data.Index,
        littleEndian: Bool
    ) -> String? {
        guard let numGeoms = readUInt32(data, offset: &offset, littleEndian: littleEndian) else {
            return nil
        }
        var points: [String] = []
        for _ in 0 ..< numGeoms {
            guard let geom = parseWKBGeometry(data, offset: &offset) else { return nil }
            if geom.hasPrefix("POINT("), geom.hasSuffix(")") {
                let ns = geom as NSString
                points.append(ns.substring(with: NSRange(location: 6, length: ns.length - 7)))
            } else {
                points.append(geom)
            }
        }
        return "MULTIPOINT(\(points.joined(separator: ", ")))"
    }

    private static func parseMultiLineString(
        _ data: Data.SubSequence,
        offset: inout Data.Index,
        littleEndian: Bool
    ) -> String? {
        guard let numGeoms = readUInt32(data, offset: &offset, littleEndian: littleEndian) else {
            return nil
        }
        var lineStrings: [String] = []
        for _ in 0 ..< numGeoms {
            guard let geom = parseWKBGeometry(data, offset: &offset) else { return nil }
            if geom.hasPrefix("LINESTRING("), geom.hasSuffix(")") {
                let ns = geom as NSString
                lineStrings.append("(\(ns.substring(with: NSRange(location: 11, length: ns.length - 12))))")
            } else {
                lineStrings.append(geom)
            }
        }
        return "MULTILINESTRING(\(lineStrings.joined(separator: ", ")))"
    }

    private static func parseMultiPolygon(
        _ data: Data.SubSequence,
        offset: inout Data.Index,
        littleEndian: Bool
    ) -> String? {
        guard let numGeoms = readUInt32(data, offset: &offset, littleEndian: littleEndian) else {
            return nil
        }
        var polygons: [String] = []
        for _ in 0 ..< numGeoms {
            guard let geom = parseWKBGeometry(data, offset: &offset) else { return nil }
            if geom.hasPrefix("POLYGON("), geom.hasSuffix(")") {
                let ns = geom as NSString
                polygons.append("(\(ns.substring(with: NSRange(location: 8, length: ns.length - 9))))")
            } else {
                polygons.append(geom)
            }
        }
        return "MULTIPOLYGON(\(polygons.joined(separator: ", ")))"
    }

    private static func parseGeometryCollection(
        _ data: Data.SubSequence,
        offset: inout Data.Index,
        littleEndian: Bool
    ) -> String? {
        guard let numGeoms = readUInt32(data, offset: &offset, littleEndian: littleEndian) else {
            return nil
        }
        var geoms: [String] = []
        for _ in 0 ..< numGeoms {
            guard let geom = parseWKBGeometry(data, offset: &offset) else { return nil }
            geoms.append(geom)
        }
        return "GEOMETRYCOLLECTION(\(geoms.joined(separator: ", ")))"
    }

    private static func readUInt32(
        _ data: Data.SubSequence,
        offset: inout Data.Index,
        littleEndian: Bool
    ) -> UInt32? {
        let endOffset = data.index(offset, offsetBy: 4, limitedBy: data.endIndex) ?? data.endIndex
        guard data.distance(from: offset, to: endOffset) == 4 else { return nil }

        let bytes = data[offset ..< endOffset]
        offset = endOffset

        if littleEndian {
            return bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
        } else {
            return bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
        }
    }

    private static func readFloat64(
        _ data: Data.SubSequence,
        offset: inout Data.Index,
        littleEndian: Bool
    ) -> Double? {
        let endOffset = data.index(offset, offsetBy: 8, limitedBy: data.endIndex) ?? data.endIndex
        guard data.distance(from: offset, to: endOffset) == 8 else { return nil }

        let bytes = data[offset ..< endOffset]
        offset = endOffset

        let bits: UInt64
        if littleEndian {
            bits = bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).littleEndian }
        } else {
            bits = bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).bigEndian }
        }
        return Double(bitPattern: bits)
    }

    private static func readPointList(
        _ data: Data.SubSequence,
        offset: inout Data.Index,
        littleEndian: Bool
    ) -> String? {
        guard let numPoints = readUInt32(data, offset: &offset, littleEndian: littleEndian) else {
            return nil
        }
        var coords: [String] = []
        for _ in 0 ..< numPoints {
            guard let x = readFloat64(data, offset: &offset, littleEndian: littleEndian),
                  let y = readFloat64(data, offset: &offset, littleEndian: littleEndian) else {
                return nil
            }
            coords.append("\(formatCoord(x)) \(formatCoord(y))")
        }
        return coords.joined(separator: ", ")
    }

    private static func formatCoord(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e15 {
            return String(format: "%.1f", value)
        }
        let formatted = String(format: "%.15g", value)
        return formatted
    }

    static func hexString(_ data: Data) -> String {
        if data.isEmpty { return "" }
        return "0x" + data.map { String(format: "%02X", $0) }.joined()
    }
}
