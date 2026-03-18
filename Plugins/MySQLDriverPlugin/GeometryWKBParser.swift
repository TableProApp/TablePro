//
//  GeometryWKBParser.swift
//  TablePro
//
//  Parses MySQL's internal WKB (Well-Known Binary) geometry format
//  into human-readable WKT (Well-Known Text) strings.
//

import Foundation

enum GeometryWKBParser {
    /// Parses MySQL's internal geometry binary format to WKT string.
    ///
    /// MySQL internal binary format:
    /// - Bytes 0-3: SRID (uint32, little-endian)
    /// - Byte 4: byte order (0x01 = LE, 0x00 = BE)
    /// - Bytes 5-8: WKB type code
    /// - Remaining: coordinates per geometry type
    static func parse(_ data: Data) -> String {
        guard data.count >= 9 else {
            return hexString(data)
        }

        // Skip 4-byte SRID prefix
        let wkbData = data.dropFirst(4)
        var offset = wkbData.startIndex
        return parseWKBGeometry(wkbData, offset: &offset) ?? hexString(data)
    }

    /// Parses raw buffer pointer (used from MariaDBConnection row loop)
    static func parse(_ buffer: UnsafeRawBufferPointer) -> String {
        let data = Data(buffer)
        return parse(data)
    }

    // MARK: - Private Parsing

    private static func parseWKBGeometry(_ data: Data.SubSequence, offset: inout Data.Index) -> String? {
        guard offset < data.endIndex else { return nil }

        // Byte order: 0x00 = big-endian, 0x01 = little-endian
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

    // MARK: - Binary Reading Helpers

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
