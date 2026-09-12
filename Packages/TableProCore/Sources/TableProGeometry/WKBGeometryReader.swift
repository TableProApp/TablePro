import Foundation

/// Reads WKB, PostGIS EWKB, and MySQL's internal SRID-prefixed variant.
///
/// Three dialects share one body. Plain OGC WKB carries the type alone; ISO WKB adds 1000, 2000 or
/// 3000 to it for Z, M and ZM; PostGIS EWKB sets high bits instead (measured on 3.6.4 wire hex:
/// `0101000020` is SRID, `01010000A0` Z+SRID, `0101000060` M+SRID, `01010000E0` Z+M+SRID). All
/// three are accepted, because a single PostGIS column can hand over any of them depending on how
/// the value was written.
///
/// Two facts that a hand-rolled reader gets wrong and that are measured here. A nested geometry
/// inside a collection carries its **own** byte-order byte, so endianness is re-read per member
/// rather than inherited. And `POINT EMPTY` is written as two NaN doubles (`000000000000F87F`),
/// not as a zero-length body.
public enum WKBGeometryReader {
    private enum Flags {
        static let srid: UInt32 = 0x2000_0000
        static let z: UInt32 = 0x8000_0000
        static let m: UInt32 = 0x4000_0000
    }

    private static let unsupportedTypes: [UInt32: String] = [
        8: "CIRCULARSTRING", 9: "COMPOUNDCURVE", 10: "CURVEPOLYGON", 11: "MULTICURVE",
        12: "MULTISURFACE", 13: "CURVE", 14: "SURFACE", 15: "POLYHEDRALSURFACE",
        16: "TIN", 17: "TRIANGLE",
    ]

    public static func read(hex: String) -> Result<SpatialValue, SpatialReadFailure> {
        guard let bytes = decodeHex(hex) else { return .failure(.notGeometry) }
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

    private static func decodeHex(_ text: String) -> [UInt8]? {
        let utf8 = Array(text.utf8)
        guard !utf8.isEmpty, utf8.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(utf8.count / 2)
        var high: UInt8?
        for byte in utf8 {
            let nibble: UInt8
            switch byte {
            case 0x30 ... 0x39: nibble = byte - 0x30
            case 0x41 ... 0x46: nibble = byte - 0x41 + 10
            case 0x61 ... 0x66: nibble = byte - 0x61 + 10
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

    private struct Cursor {
        private let bytes: [UInt8]
        private var index: Int
        private var depth = 0
        var failure: SpatialReadFailure?

        init(_ bytes: [UInt8]) {
            self.bytes = bytes
            index = 0
        }

        var isAtEnd: Bool { index >= bytes.count }

        mutating func readGeometry(inheritedSRID: Int32?) -> SpatialValue? {
            depth += 1
            defer { depth -= 1 }
            guard depth <= SpatialLimits.maximumNestingDepth else {
                failure = .malformed
                return nil
            }
            guard let order = readByteOrder() else { return nil }
            guard let rawType = readUInt32(order) else { return nil }

            var type = rawType & 0x0FFF_FFFF
            var hasZ = rawType & Flags.z != 0
            var hasM = rawType & Flags.m != 0
            let hasSRID = rawType & Flags.srid != 0

            if type >= 3000 {
                type -= 3000
                hasZ = true
                hasM = true
            } else if type >= 2000 {
                type -= 2000
                hasM = true
            } else if type >= 1000 {
                type -= 1000
                hasZ = true
            }

            var srid = inheritedSRID
            if hasSRID {
                guard let raw = readUInt32(order) else { return nil }
                srid = raw == 0 ? nil : Int32(bitPattern: raw)
            }

            if let name = WKBGeometryReader.unsupportedTypes[type] {
                failure = .unsupportedGeometryType(name)
                return nil
            }

            let ordinates = 2 + (hasZ ? 1 : 0) + (hasM ? 1 : 0)
            guard let geometry = readBody(type: type, order: order, ordinates: ordinates, srid: srid) else {
                return nil
            }
            return SpatialValue(srid: srid, geometry: geometry)
        }

        private mutating func readBody(
            type: UInt32,
            order: ByteOrder,
            ordinates: Int,
            srid: Int32?
        ) -> SpatialGeometry? {
            switch type {
            case 1:
                guard let point = readPoint(order, ordinates) else { return nil }
                /// A NaN ordinate pair is how every producer writes `POINT EMPTY`; there is no
                /// zero-length point body in the format.
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
                        failure = .malformed
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
                        failure = .malformed
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
                        failure = .malformed
                        return nil
                    }
                }
                return .multiPolygon(polygons)
            case 7:
                guard let children = readChildren(order: order, srid: srid) else { return nil }
                return .collection(children)
            default:
                failure = .malformed
                return nil
            }
        }

        /// Reads a counted run of sub-geometries, each of which re-declares its own byte order.
        private mutating func readChildren(order: ByteOrder, srid: Int32?) -> [SpatialGeometry]? {
            guard let count = readUInt32(order) else { return nil }
            guard count <= UInt32(bytes.count) else {
                failure = .malformed
                return nil
            }
            var children: [SpatialGeometry] = []
            children.reserveCapacity(Int(count))
            for _ in 0 ..< count {
                guard let child = readGeometry(inheritedSRID: srid) else { return nil }
                children.append(child.geometry)
            }
            return children
        }

        private mutating func readRings(_ order: ByteOrder, _ ordinates: Int) -> [[SpatialPoint]]? {
            guard let count = readUInt32(order) else { return nil }
            guard count <= UInt32(bytes.count) else {
                failure = .malformed
                return nil
            }
            var rings: [[SpatialPoint]] = []
            rings.reserveCapacity(Int(count))
            for _ in 0 ..< count {
                guard let ring = readPointRun(order, ordinates) else { return nil }
                rings.append(ring)
            }
            return rings
        }

        private mutating func readPointRun(_ order: ByteOrder, _ ordinates: Int) -> [SpatialPoint]? {
            guard let count = readUInt32(order) else { return nil }
            /// A corrupt or truncated buffer can declare a huge count. Rejecting it against the
            /// bytes actually remaining stops a reserveCapacity of hundreds of megabytes before it
            /// is attempted.
            let needed = Int(count) * ordinates * 8
            guard needed >= 0, bytes.count - index >= needed else {
                failure = .malformed
                return nil
            }
            var points: [SpatialPoint] = []
            points.reserveCapacity(Int(count))
            for _ in 0 ..< count {
                guard let point = readPoint(order, ordinates) else { return nil }
                points.append(point)
            }
            return points
        }

        private mutating func readPoint(_ order: ByteOrder, _ ordinates: Int) -> SpatialPoint? {
            guard let x = readDouble(order), let y = readDouble(order) else { return nil }
            for _ in 2 ..< ordinates {
                guard readDouble(order) != nil else { return nil }
            }
            return SpatialPoint(x: x, y: y)
        }

        private mutating func readByteOrder() -> ByteOrder? {
            guard index < bytes.count else {
                failure = .malformed
                return nil
            }
            let raw = bytes[index]
            index += 1
            switch raw {
            case 0: return .big
            case 1: return .little
            default:
                failure = .notGeometry
                return nil
            }
        }

        private mutating func readUInt32(_ order: ByteOrder) -> UInt32? {
            guard bytes.count - index >= 4 else {
                failure = .malformed
                return nil
            }
            let slice = bytes[index ..< index + 4]
            index += 4
            var value: UInt32 = 0
            if order == .little {
                for (offset, byte) in slice.enumerated() { value |= UInt32(byte) << (8 * offset) }
            } else {
                for byte in slice { value = value << 8 | UInt32(byte) }
            }
            return value
        }

        private mutating func readDouble(_ order: ByteOrder) -> Double? {
            guard bytes.count - index >= 8 else {
                failure = .malformed
                return nil
            }
            let slice = bytes[index ..< index + 8]
            index += 8
            var bits: UInt64 = 0
            if order == .little {
                for (offset, byte) in slice.enumerated() { bits |= UInt64(byte) << (8 * offset) }
            } else {
                for byte in slice { bits = bits << 8 | UInt64(byte) }
            }
            return Double(bitPattern: bits)
        }
    }

    private enum ByteOrder {
        case little
        case big
    }
}
