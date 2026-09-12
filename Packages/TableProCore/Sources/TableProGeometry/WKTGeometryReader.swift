import Foundation

/// Reads the WKT and EWKT spellings the engines TablePro ships actually emit.
///
/// There is no single spelling, so this is deliberately tolerant in ways the OGC grammar is not.
/// Measured against live servers: PostGIS 3.6.4 writes `SRID=n;` only when the SRID is non-zero,
/// writes XYZ as a bare `POINT(1 2 3)` with no tag, writes XYM as `POINTM(1 2 3)` rather than the
/// OGC `POINT M (...)`, and always writes MULTIPOINT bare as `MULTIPOINT(1 2,3 4)`. MySQL 8.4
/// writes the parenthesised `MULTIPOINT((1 2),(3 4))` and emits an invalid `GEOMETRYCOLLECTION()`
/// for an empty collection. DuckDB 1.5.4 puts a space before the paren: `POINT (1 2)`.
///
/// A curved or polyhedral type is refused by name rather than dropped. PostGIS hands out
/// CIRCULARSTRING, CURVEPOLYGON and TIN values that no amount of parsing turns into line segments,
/// and a pane that silently draws nothing teaches the reader nothing.
public enum WKTGeometryReader {
    public static func read(_ text: String) -> Result<SpatialValue, SpatialReadFailure> {
        var scanner = Scanner(text)
        let srid = scanner.readSRIDPrefix()
        guard let geometry = scanner.readGeometry() else {
            return .failure(scanner.failure ?? .notGeometry)
        }
        scanner.skipWhitespace()
        guard scanner.isAtEnd else { return .failure(.malformed) }
        return .success(SpatialValue(srid: srid, geometry: geometry))
    }

    /// Whether the text opens like a geometry, without committing to a full parse.
    ///
    /// The value sniffer asks this to choose between the WKT, WKB-hex and GeoJSON readers, so it
    /// has to be cheap and must not allocate a parse tree for a column of ordinary strings.
    public static func looksLikeWKT(_ text: String) -> Bool {
        var scanner = Scanner(text)
        _ = scanner.readSRIDPrefix()
        scanner.skipWhitespace()
        guard let keyword = scanner.peekKeyword() else { return false }
        return Keyword.resolve(keyword) != nil
    }

    static let unsupportedKeywords: Set<String> = [
        "CIRCULARSTRING", "COMPOUNDCURVE", "CURVEPOLYGON", "MULTICURVE",
        "MULTISURFACE", "POLYHEDRALSURFACE", "TIN", "TRIANGLE",
    ]

    enum Keyword: String {
        case point = "POINT"
        case lineString = "LINESTRING"
        case polygon = "POLYGON"
        case multiPoint = "MULTIPOINT"
        case multiLineString = "MULTILINESTRING"
        case multiPolygon = "MULTIPOLYGON"
        case geometryCollection = "GEOMETRYCOLLECTION"
        /// MySQL 8.0.11 renamed the type and its catalog, `SHOW CREATE TABLE` and its WKT all say
        /// `GEOMCOLLECTION`. Measured on MySQL 8.4.11.
        case geomCollection = "GEOMCOLLECTION"

        var isCollection: Bool { self == .geometryCollection || self == .geomCollection }

        /// Resolves a keyword that may carry a dimensionality tag fused onto it.
        ///
        /// Tried longest-first, because stripping `M` from `MULTIPOINT` before trying the whole
        /// word turns it into `MULTIPOIN` and loses the type.
        static func resolve(_ word: String) -> Keyword? {
            if let exact = Keyword(rawValue: word) { return exact }
            for suffix in ["ZM", "Z", "M"] where word.hasSuffix(suffix) {
                let base = String(word.dropLast(suffix.count))
                if let stripped = Keyword(rawValue: base) { return stripped }
            }
            return nil
        }
    }

    struct Scanner {
        private let bytes: [UInt8]
        private var index: Int
        var failure: SpatialReadFailure?
        private var depth = 0

        init(_ text: String) {
            bytes = Array(text.utf8)
            index = 0
        }

        var isAtEnd: Bool { index >= bytes.count }

        mutating func skipWhitespace() {
            while index < bytes.count, bytes[index] == 0x20 || bytes[index] == 0x09
                || bytes[index] == 0x0A || bytes[index] == 0x0D
            {
                index += 1
            }
        }

        /// Consumes an `SRID=<int>;` prefix if one is present, leaving the cursor untouched if not.
        mutating func readSRIDPrefix() -> Int32? {
            let start = index
            skipWhitespace()
            guard matchKeyword("SRID") else {
                index = start
                return nil
            }
            skipWhitespace()
            guard consume(0x3D) else {
                index = start
                return nil
            }
            skipWhitespace()
            var negative = false
            if index < bytes.count, bytes[index] == 0x2D {
                negative = true
                index += 1
            }
            var value: Int64 = 0
            var digits = 0
            while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 {
                value = value * 10 + Int64(bytes[index] - 0x30)
                if value > Int64(Int32.max) { value = Int64(Int32.max) }
                digits += 1
                index += 1
            }
            skipWhitespace()
            guard digits > 0, consume(0x3B) else {
                index = start
                return nil
            }
            return Int32(negative ? -value : value)
        }

        mutating func readGeometry() -> SpatialGeometry? {
            depth += 1
            defer { depth -= 1 }
            guard depth <= SpatialLimits.maximumNestingDepth else {
                failure = .malformed
                return nil
            }
            skipWhitespace()
            guard let word = readKeyword() else {
                failure = .notGeometry
                return nil
            }
            if WKTGeometryReader.unsupportedKeywords.contains(word) {
                failure = .unsupportedGeometryType(word)
                return nil
            }
            guard let keyword = WKTGeometryReader.Keyword.resolve(word) else {
                failure = .notGeometry
                return nil
            }
            skipWhitespace()
            if matchKeyword("EMPTY") { return .empty }
            if matchKeyword("ZM") || matchKeyword("Z") || matchKeyword("M") {
                skipWhitespace()
                if matchKeyword("EMPTY") { return .empty }
            }
            guard consume(0x28) else {
                failure = .malformed
                return nil
            }
            skipWhitespace()
            /// MySQL emits `GEOMETRYCOLLECTION()` for an empty collection, which no grammar allows.
            if consume(0x29) { return .empty }
            let body = readBody(for: keyword)
            guard body != nil else { return nil }
            skipWhitespace()
            guard consume(0x29) else {
                failure = .malformed
                return nil
            }
            return body
        }

        private mutating func readBody(for keyword: Keyword) -> SpatialGeometry? {
            switch keyword {
            case .point:
                guard let point = readPoint() else { return nil }
                return .point(point)
            case .lineString:
                guard let points = readPointList() else { return nil }
                return .lineString(points)
            case .polygon:
                guard let rings = readRingList() else { return nil }
                return .polygon(rings: rings)
            case .multiPoint:
                guard let points = readMultiPointBody() else { return nil }
                return .multiPoint(points)
            case .multiLineString:
                guard let lines = readRingList() else { return nil }
                return .multiLineString(lines)
            case .multiPolygon:
                guard let polygons = readPolygonList() else { return nil }
                return .multiPolygon(polygons)
            case .geometryCollection, .geomCollection:
                guard let children = readCollectionBody() else { return nil }
                return .collection(children)
            }
        }

        /// Both MULTIPOINT spellings are legal and both ship: PostGIS writes the bare form and
        /// MySQL the parenthesised one, so the shape is decided per element rather than up front.
        private mutating func readMultiPointBody() -> [SpatialPoint]? {
            var points: [SpatialPoint] = []
            repeat {
                skipWhitespace()
                if consume(0x28) {
                    skipWhitespace()
                    if consume(0x29) { continue }
                    guard let point = readPoint() else { return nil }
                    skipWhitespace()
                    guard consume(0x29) else {
                        failure = .malformed
                        return nil
                    }
                    points.append(point)
                } else if matchKeyword("EMPTY") {
                    continue
                } else {
                    guard let point = readPoint() else { return nil }
                    points.append(point)
                }
                skipWhitespace()
            } while consume(0x2C)
            return points
        }

        private mutating func readCollectionBody() -> [SpatialGeometry]? {
            var children: [SpatialGeometry] = []
            repeat {
                guard let child = readGeometry() else { return nil }
                children.append(child)
                skipWhitespace()
            } while consume(0x2C)
            return children
        }

        private mutating func readPolygonList() -> [[[SpatialPoint]]]? {
            var polygons: [[[SpatialPoint]]] = []
            repeat {
                skipWhitespace()
                if matchKeyword("EMPTY") {
                    polygons.append([])
                    skipWhitespace()
                    continue
                }
                guard consume(0x28) else {
                    failure = .malformed
                    return nil
                }
                guard let rings = readRingList() else { return nil }
                skipWhitespace()
                guard consume(0x29) else {
                    failure = .malformed
                    return nil
                }
                polygons.append(rings)
                skipWhitespace()
            } while consume(0x2C)
            return polygons
        }

        private mutating func readRingList() -> [[SpatialPoint]]? {
            var rings: [[SpatialPoint]] = []
            repeat {
                skipWhitespace()
                if matchKeyword("EMPTY") {
                    rings.append([])
                    skipWhitespace()
                    continue
                }
                guard consume(0x28) else {
                    failure = .malformed
                    return nil
                }
                guard let points = readPointList() else { return nil }
                skipWhitespace()
                guard consume(0x29) else {
                    failure = .malformed
                    return nil
                }
                rings.append(points)
                skipWhitespace()
            } while consume(0x2C)
            return rings
        }

        private mutating func readPointList() -> [SpatialPoint]? {
            var points: [SpatialPoint] = []
            repeat {
                skipWhitespace()
                guard let point = readPoint() else { return nil }
                points.append(point)
                skipWhitespace()
            } while consume(0x2C)
            return points
        }

        /// Reads two to four ordinates and keeps the first two.
        ///
        /// The count is what distinguishes XY from XYZ, XYM and XYZM in PostGIS's bare spelling, so
        /// the extra ordinates are consumed rather than rejected; dropping them is what MapKit
        /// requires, since it draws on a sphere with no altitude and no measure.
        private mutating func readPoint() -> SpatialPoint? {
            skipWhitespace()
            guard let x = readDouble(), let y = readDouble() else {
                failure = .malformed
                return nil
            }
            var extra = 0
            while extra < 2, peekStartsNumber() {
                guard readDouble() != nil else {
                    failure = .malformed
                    return nil
                }
                extra += 1
            }
            return SpatialPoint(x: x, y: y)
        }

        private mutating func peekStartsNumber() -> Bool {
            let saved = index
            skipWhitespace()
            defer { index = saved }
            guard index < bytes.count else { return false }
            let byte = bytes[index]
            return (byte >= 0x30 && byte <= 0x39) || byte == 0x2D || byte == 0x2B || byte == 0x2E
        }

        private mutating func readDouble() -> Double? {
            skipWhitespace()
            let start = index
            if index < bytes.count, bytes[index] == 0x2D || bytes[index] == 0x2B { index += 1 }
            var sawDigit = false
            while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 {
                index += 1
                sawDigit = true
            }
            if index < bytes.count, bytes[index] == 0x2E {
                index += 1
                while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 {
                    index += 1
                    sawDigit = true
                }
            }
            guard sawDigit else {
                index = start
                return nil
            }
            if index < bytes.count, bytes[index] == 0x65 || bytes[index] == 0x45 {
                let exponentStart = index
                index += 1
                if index < bytes.count, bytes[index] == 0x2D || bytes[index] == 0x2B { index += 1 }
                var sawExponentDigit = false
                while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 {
                    index += 1
                    sawExponentDigit = true
                }
                if !sawExponentDigit { index = exponentStart }
            }
            var token = Array(bytes[start ..< index])
            token.append(0)
            return token.withUnsafeBufferPointer { buffer in
                buffer.baseAddress.flatMap { base in
                    base.withMemoryRebound(to: CChar.self, capacity: token.count) { strtod($0, nil) }
                }
            }
        }

        mutating func peekKeyword() -> String? {
            let saved = index
            defer { index = saved }
            return readKeyword()
        }

        private mutating func readKeyword() -> String? {
            skipWhitespace()
            let start = index
            while index < bytes.count, isLetter(bytes[index]) { index += 1 }
            guard index > start else { return nil }
            return String(decoding: bytes[start ..< index], as: UTF8.self).uppercased()
        }

        private mutating func matchKeyword(_ keyword: String) -> Bool {
            let saved = index
            skipWhitespace()
            let start = index
            while index < bytes.count, isLetter(bytes[index]) { index += 1 }
            guard index > start else {
                index = saved
                return false
            }
            let word = String(decoding: bytes[start ..< index], as: UTF8.self).uppercased()
            guard word == keyword else {
                index = saved
                return false
            }
            return true
        }

        private mutating func consume(_ byte: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1
            return true
        }

        private func isLetter(_ byte: UInt8) -> Bool {
            (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || byte == 0x5F
        }
    }
}
