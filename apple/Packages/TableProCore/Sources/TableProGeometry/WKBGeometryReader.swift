import Foundation

// WKB, ISO WKB, PostGIS EWKB and MySQL's SRID-prefixed variant: a PostGIS column can hand over any of the first three.
public enum WKBGeometryReader {
    private static let unsupportedTypes: [UInt32: String] = [
        8: "CIRCULARSTRING", 9: "COMPOUNDCURVE", 10: "CURVEPOLYGON", 11: "MULTICURVE",
        12: "MULTISURFACE", 13: "CURVE", 14: "SURFACE", 15: "POLYHEDRALSURFACE",
        16: "TIN", 17: "TRIANGLE",
    ]

    public static func read(hex: String) -> Result<SpatialValue, SpatialReadFailure> {
        guard let bytes = WKBCursor.bytes(fromHex: hex) else { return .failure(.notGeometry) }
        return read(bytes: bytes)
    }

    public static func read(bytes: [UInt8]) -> Result<SpatialValue, SpatialReadFailure> {
        var cursor = Cursor(bytes)
        guard let value = cursor.readGeometry(inheritedSRID: nil) else {
            return .failure(cursor.failure ?? .malformed)
        }
        guard cursor.isAtEnd else { return .failure(.malformed) }
        return .success(value)
    }

    /// Reads the format `libmariadb` hands back for a MySQL or MariaDB geometry column: a 4-byte
    /// little-endian SRID, then ordinary WKB.
    ///
    /// The SRID is returned rather than skipped. It is the only thing that says whether the
    /// coordinates are degrees, and both servers store a geographic SRS **longitude first** in
    /// these bytes even though `ST_AsText` prints latitude first for SRID 4326 (measured
    /// byte-identical on MySQL 8.4.11 and MariaDB 12.3.3). So the coordinates need no reordering
    /// and the SRID must not be discarded.
    public static func read(mysqlInternal bytes: [UInt8]) -> Result<SpatialValue, SpatialReadFailure> {
        guard bytes.count >= 5 else { return .failure(.notGeometry) }
        let srid = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
        var cursor = Cursor(Array(bytes.dropFirst(4)))
        guard let value = cursor.readGeometry(inheritedSRID: nil) else {
            return .failure(cursor.failure ?? .malformed)
        }
        guard cursor.isAtEnd else { return .failure(.malformed) }
        return .success(SpatialValue(srid: srid == 0 ? nil : Int32(bitPattern: srid), geometry: value.geometry))
    }

    public static func looksLikeHex(_ text: String) -> Bool {
        let utf8 = text.utf8
        var count = 0
        for byte in utf8 {
            let isHexDigit = (byte >= 0x30 && byte <= 0x39)
                || (byte >= 0x41 && byte <= 0x46)
                || (byte >= 0x61 && byte <= 0x66)
            guard isHexDigit else { return false }
            count += 1
        }
        return count >= 10 && count % 2 == 0
    }

    private struct Cursor {
        private var wkb: WKBCursor
        private var depth = 0

        init(_ bytes: [UInt8]) {
            wkb = WKBCursor(bytes)
        }

        var failure: SpatialReadFailure? { wkb.failure }

        var isAtEnd: Bool { wkb.isAtEnd }

        mutating func readGeometry(inheritedSRID: Int32?) -> SpatialValue? {
            depth += 1
            defer { depth -= 1 }
            guard depth <= SpatialLimits.maximumNestingDepth else {
                wkb.failure = .malformed
                return nil
            }
            guard let header = wkb.readHeader() else { return nil }
            let srid = header.declaresSRID ? header.srid : inheritedSRID

            if let name = WKBGeometryReader.unsupportedTypes[header.type] {
                wkb.failure = .unsupportedGeometryType(name)
                return nil
            }

            guard let geometry = readBody(
                type: header.type,
                order: header.order,
                ordinates: header.ordinates,
                srid: srid
            ) else {
                return nil
            }
            return SpatialValue(srid: srid, geometry: geometry)
        }

        private mutating func readBody(
            type: UInt32,
            order: WKBCursor.ByteOrder,
            ordinates: Int,
            srid: Int32?
        ) -> SpatialGeometry? {
            switch type {
            case 1:
                guard let point = readPoint(order, ordinates) else { return nil }
                // A NaN ordinate pair is how every producer writes POINT EMPTY.
                if point.x.isNaN || point.y.isNaN { return .empty }
                return .point(point)
            case 2:
                guard let points = readPointRun(order, ordinates) else { return nil }
                return .lineString(points)
            case 3:
                guard let rings = readRings(order, ordinates) else { return nil }
                return .polygon(rings: rings)
            case 4:
                guard let children = readChildren(order: order, srid: srid) else { return nil }
                var points: [SpatialPoint] = []
                points.reserveCapacity(children.count)
                for child in children {
                    switch child {
                    case .point(let point): points.append(point)
                    case .empty: continue
                    default:
                        wkb.failure = .malformed
                        return nil
                    }
                }
                return .multiPoint(points)
            case 5:
                guard let children = readChildren(order: order, srid: srid) else { return nil }
                var lines: [[SpatialPoint]] = []
                lines.reserveCapacity(children.count)
                for child in children {
                    switch child {
                    case .lineString(let points): lines.append(points)
                    case .empty: lines.append([])
                    default:
                        wkb.failure = .malformed
                        return nil
                    }
                }
                return .multiLineString(lines)
            case 6:
                guard let children = readChildren(order: order, srid: srid) else { return nil }
                var polygons: [[[SpatialPoint]]] = []
                polygons.reserveCapacity(children.count)
                for child in children {
                    switch child {
                    case .polygon(let rings): polygons.append(rings)
                    case .empty: polygons.append([])
                    default:
                        wkb.failure = .malformed
                        return nil
                    }
                }
                return .multiPolygon(polygons)
            case 7:
                guard let children = readChildren(order: order, srid: srid) else { return nil }
                return .collection(children)
            default:
                wkb.failure = .malformed
                return nil
            }
        }

        // Each member re-declares its own byte order.
        private mutating func readChildren(order: WKBCursor.ByteOrder, srid: Int32?) -> [SpatialGeometry]? {
            // A member is at least its byte-order byte and type word.
            guard let count = wkb.readCount(order, minimumElementSize: 5) else { return nil }
            var children: [SpatialGeometry] = []
            children.reserveCapacity(count)
            for _ in 0 ..< count {
                guard let child = readGeometry(inheritedSRID: srid) else { return nil }
                children.append(child.geometry)
            }
            return children
        }

        private mutating func readRings(_ order: WKBCursor.ByteOrder, _ ordinates: Int) -> [[SpatialPoint]]? {
            guard let count = wkb.readCount(order, minimumElementSize: 4) else { return nil }
            var rings: [[SpatialPoint]] = []
            rings.reserveCapacity(count)
            for _ in 0 ..< count {
                guard let ring = readPointRun(order, ordinates) else { return nil }
                rings.append(ring)
            }
            return rings
        }

        private mutating func readPointRun(_ order: WKBCursor.ByteOrder, _ ordinates: Int) -> [SpatialPoint]? {
            guard let count = wkb.readCount(order, minimumElementSize: ordinates * 8) else { return nil }
            var points: [SpatialPoint] = []
            points.reserveCapacity(count)
            for _ in 0 ..< count {
                guard let point = readPoint(order, ordinates) else { return nil }
                points.append(point)
            }
            return points
        }

        private mutating func readPoint(_ order: WKBCursor.ByteOrder, _ ordinates: Int) -> SpatialPoint? {
            guard let x = wkb.readDouble(order), let y = wkb.readDouble(order) else { return nil }
            for _ in 2 ..< ordinates {
                guard wkb.readDouble(order) != nil else { return nil }
            }
            return SpatialPoint(x: x, y: y)
        }
    }
}
