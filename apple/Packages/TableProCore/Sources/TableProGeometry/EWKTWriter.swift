import Foundation

// Hex EWKB to the text ST_AsEWKT gives (liblwgeom extended WKT), Z, M, curves and empty members kept, with every digit
// an ordinate needs to read back unchanged.
public enum EWKTWriter {
    public static func string(fromHex hex: String) -> String? {
        guard let bytes = WKBCursor.bytes(fromHex: hex) else { return nil }
        var writer = Writer(cursor: WKBCursor(bytes))
        guard let header = writer.cursor.readHeader(), let kind = Kind(rawValue: header.type) else { return nil }
        if let srid = header.srid {
            writer.output = "SRID=\(srid);"
        }
        guard writer.write(kind, header, typed: true), writer.cursor.isAtEnd else { return nil }
        return writer.output
    }

    private enum Kind: UInt32 {
        case point = 1
        case lineString, polygon, multiPoint, multiLineString, multiPolygon, collection
        case circularString, compoundCurve, curvePolygon, multiCurve, multiSurface
        case polyhedralSurface = 15
        case tin, triangle

        var keyword: String {
            switch self {
            case .point: return "POINT"
            case .lineString: return "LINESTRING"
            case .polygon: return "POLYGON"
            case .multiPoint: return "MULTIPOINT"
            case .multiLineString: return "MULTILINESTRING"
            case .multiPolygon: return "MULTIPOLYGON"
            case .collection: return "GEOMETRYCOLLECTION"
            case .circularString: return "CIRCULARSTRING"
            case .compoundCurve: return "COMPOUNDCURVE"
            case .curvePolygon: return "CURVEPOLYGON"
            case .multiCurve: return "MULTICURVE"
            case .multiSurface: return "MULTISURFACE"
            case .polyhedralSurface: return "POLYHEDRALSURFACE"
            case .tin: return "TIN"
            case .triangle: return "TRIANGLE"
            }
        }

        // Which members a container may hold, and which of them it writes without a keyword.
        var members: (allowed: Set<Kind>, bare: Set<Kind>)? {
            switch self {
            case .multiPoint: return ([.point], [.point])
            case .multiLineString: return ([.lineString], [.lineString])
            case .multiPolygon, .polyhedralSurface: return ([.polygon], [.polygon])
            case .compoundCurve: return ([.lineString, .circularString], [.lineString])
            case .curvePolygon, .multiCurve: return ([.lineString, .circularString, .compoundCurve], [.lineString])
            case .multiSurface: return ([.polygon, .curvePolygon], [.polygon])
            case .tin: return ([.triangle], [.triangle])
            case .collection: return (Set(Kind.allCases), [])
            case .point, .lineString, .polygon, .circularString, .triangle: return nil
            }
        }

        static let allCases: [Kind] = [
            .point, .lineString, .polygon, .multiPoint, .multiLineString, .multiPolygon, .collection,
            .circularString, .compoundCurve, .curvePolygon, .multiCurve, .multiSurface, .polyhedralSurface,
            .tin, .triangle,
        ]
    }

    private struct Writer {
        var cursor: WKBCursor
        var output = ""
        private var depth = 0

        init(cursor: WKBCursor) {
            self.cursor = cursor
        }

        mutating func write(_ kind: Kind, _ header: WKBCursor.Header, typed: Bool) -> Bool {
            depth += 1
            defer { depth -= 1 }
            guard depth <= SpatialLimits.maximumNestingDepth else { return false }
            if typed {
                output += kind.keyword
                if header.hasM, !header.hasZ { output += "M" }
            }
            switch kind {
            case .point:
                guard let point = readPoint(header) else { return false }
                // EWKB has no empty point: every ordinate NaN stands for POINT EMPTY.
                if point.allSatisfy(\.isNaN) {
                    writeEmpty()
                } else {
                    // A multipoint writes its members without parentheses.
                    let ordinates = Self.spelled(point)
                    output += typed ? "(\(ordinates))" : ordinates
                }
                return true
            case .lineString, .circularString:
                guard let points = readRun(header) else { return false }
                if points.isEmpty { writeEmpty() } else { output += "(\(points))" }
                return true
            case .polygon, .triangle:
                guard let count = cursor.readCount(header.order, minimumElementSize: 4) else { return false }
                guard count > 0 else {
                    writeEmpty()
                    return true
                }
                var rings: [String] = []
                for _ in 0 ..< count {
                    guard let ring = readRun(header) else { return false }
                    rings.append("(\(ring))")
                }
                output += "(\(rings.joined(separator: ",")))"
                return true
            default:
                return writeMembers(of: kind, header)
            }
        }

        private mutating func writeMembers(of kind: Kind, _ header: WKBCursor.Header) -> Bool {
            guard let members = kind.members,
                  let count = cursor.readCount(header.order, minimumElementSize: 5) else { return false }
            guard count > 0 else {
                writeEmpty()
                return true
            }
            output += "("
            for index in 0 ..< count {
                guard let child = cursor.readHeader(), let childKind = Kind(rawValue: child.type),
                      members.allowed.contains(childKind) else { return false }
                if index > 0 { output += "," }
                guard write(childKind, child, typed: !members.bare.contains(childKind)) else { return false }
            }
            output += ")"
            return true
        }

        private mutating func writeEmpty() {
            if let last = output.last, last != "(", last != "," { output += " " }
            output += "EMPTY"
        }

        private mutating func readRun(_ header: WKBCursor.Header) -> String? {
            guard let count = cursor.readCount(header.order, minimumElementSize: header.ordinates * 8) else {
                return nil
            }
            var points: [String] = []
            points.reserveCapacity(count)
            for _ in 0 ..< count {
                guard let point = readPoint(header) else { return nil }
                points.append(Self.spelled(point))
            }
            return points.joined(separator: ",")
        }

        private mutating func readPoint(_ header: WKBCursor.Header) -> [Double]? {
            var point: [Double] = []
            for _ in 0 ..< header.ordinates {
                guard let value = cursor.readDouble(header.order) else { return nil }
                point.append(value)
            }
            return point
        }

        private static func spelled(_ point: [Double]) -> String {
            point.map(EWKTWriter.ordinate).joined(separator: " ")
        }
    }

    // liblwgeom's layout (plain, scientific at or below 1e-8 and from 1e15, no exponent padding) with the shortest
    // digits that read back as the same double. ST_AsEWKT stops at 15 decimals, which a keyless row match or a value
    // written back cannot afford.
    static func ordinate(_ value: Double) -> String {
        // ST_AsEWKT prints -0 as 0, which reads back as another double.
        guard value != 0 else { return value.sign == .minus ? "-0" : "0" }
        guard value.isFinite else { return value.isNaN ? "nan" : (value < 0 ? "-inf" : "inf") }
        let number = Digits(value)
        return value.magnitude <= 1e-8 || value.magnitude >= 1e15 ? number.scientific : number.plain
    }

    // The first digit stands for 10^exponent.
    private struct Digits {
        let negative: Bool
        let digits: Substring
        let exponent: Int

        // Swift's description is the shortest round-trip spelling, as ryu's is.
        init(_ value: Double) {
            let description = "\(value.magnitude)"
            let parts = description.split(separator: "e", maxSplits: 1)
            let mantissa = parts[0].split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
            let whole = mantissa[0]
            let all = whole + (mantissa.count == 2 ? mantissa[1] : "")
            let leadingZeros = all.prefix { $0 == "0" }.count
            let significant = all.dropFirst(leadingZeros)
            negative = value < 0
            digits = significant.prefix(significant.count - significant.reversed().prefix { $0 == "0" }.count)
            exponent = whole.count - 1 - leadingZeros + (parts.count == 2 ? Int(parts[1]) ?? 0 : 0)
        }

        var plain: String {
            guard !digits.isEmpty else { return "0" }
            let sign = negative ? "-" : ""
            if exponent < 0 {
                return sign + "0." + String(repeating: "0", count: -exponent - 1) + digits
            }
            if digits.count <= exponent + 1 {
                return sign + digits + String(repeating: "0", count: exponent + 1 - digits.count)
            }
            return sign + digits.prefix(exponent + 1) + "." + digits.dropFirst(exponent + 1)
        }

        var scientific: String {
            guard let first = digits.first else { return "0" }
            var text = (negative ? "-" : "") + String(first)
            if digits.count > 1 { text += "." + digits.dropFirst() }
            return text + (exponent < 0 ? "e-" : "e+") + String(exponent.magnitude)
        }
    }
}
