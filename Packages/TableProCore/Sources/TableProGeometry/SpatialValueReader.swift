import Foundation

/// Chooses a reader for one cell.
///
/// There is no single wire format, and the engine's own type name does not settle it: a PostGIS
/// column reports `geometry` whether the value arrived as EWKT or, when the `ST_AsEWKT` rewrite
/// failed, as raw EWKB hex. So the value is sniffed, cheaply, and the sniff is ordered by how
/// exclusive each shape is: hex digits only, then a leading brace, then a geometry keyword.
public enum SpatialValueReader {
    public static func read(_ text: String) -> Result<SpatialValue, SpatialReadFailure> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.notGeometry) }

        if WKBGeometryReader.looksLikeHex(trimmed) {
            return WKBGeometryReader.read(hex: trimmed)
        }
        if GeoJSONGeometryReader.looksLikeGeoJSON(trimmed) {
            return GeoJSONGeometryReader.read(trimmed)
        }
        if WKTGeometryReader.looksLikeWKT(trimmed) {
            return WKTGeometryReader.read(trimmed)
        }
        if let tuple = readClickHouseTuple(trimmed) {
            return .success(tuple)
        }
        if let geoPoint = readElasticsearchGeoPoint(trimmed) {
            return .success(geoPoint)
        }
        /// A keyword the readers refuse still deserves its name in the message, so the WKT reader
        /// gets the last word on text that opened like a geometry type.
        return WKTGeometryReader.read(trimmed)
    }

    /// ClickHouse streams `TabSeparatedWithNamesAndTypes`, so a `Point` arrives as the literal
    /// `(-122.4194,37.7749)` and a `Ring` or `Polygon` as nested tuples of those.
    /// ClickHouse writes a `Tuple` in parentheses and an `Array` in square brackets, so a `Point`
    /// arrives as `(1,2)` while the `Ring` around it arrives as `[(1,2),(3,4)]`. Both openers are
    /// accepted at every level; requiring parentheses throughout rejected every non-Point value.
    static func readClickHouseTuple(_ text: String) -> SpatialValue? {
        let opensGroup = text.hasPrefix("(") || text.hasPrefix("[")
        let closesGroup = text.hasSuffix(")") || text.hasSuffix("]")
        guard opensGroup, closesGroup else { return nil }
        guard let node = TupleNode.parse(text) else { return nil }
        guard let geometry = node.geometry else { return nil }
        return SpatialValue(srid: nil, geometry: geometry)
    }

    /// Elasticsearch's `geo_point` is legally six different shapes. The WKT and GeoJSON spellings
    /// are handled above; the other four are read here.
    ///
    /// The axis order differs between them, which is the trap. The `"lat,lon"` string and the
    /// `{"lat":…,"lon":…}` object are latitude-first, as Elasticsearch documents them, while the
    /// `[lon, lat]` array is longitude-first to match GeoJSON. Reading one as the other puts the
    /// point in the wrong hemisphere.
    static func readElasticsearchGeoPoint(_ text: String) -> SpatialValue? {
        if let point = objectForm(text) ?? arrayForm(text) ?? stringForm(text) ?? geohashForm(text) {
            return SpatialValue(srid: 4326, geometry: .point(point))
        }
        return nil
    }

    private static func validPoint(longitude: Double, latitude: Double) -> SpatialPoint? {
        guard longitude.isFinite, latitude.isFinite,
              latitude >= -90, latitude <= 90, longitude >= -180, longitude <= 180
        else {
            return nil
        }
        return SpatialPoint(x: longitude, y: latitude)
    }

    private static func objectForm(_ text: String) -> SpatialPoint? {
        guard text.hasPrefix("{"), let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let latitude = numeric(object["lat"]), let longitude = numeric(object["lon"] ?? object["long"])
        else {
            return nil
        }
        return validPoint(longitude: longitude, latitude: latitude)
    }

    private static func arrayForm(_ text: String) -> SpatialPoint? {
        guard text.hasPrefix("["), let data = text.data(using: .utf8),
              let values = try? JSONSerialization.jsonObject(with: data) as? [Any],
              values.count == 2,
              let longitude = numeric(values[0]), let latitude = numeric(values[1])
        else {
            return nil
        }
        return validPoint(longitude: longitude, latitude: latitude)
    }

    private static func stringForm(_ text: String) -> SpatialPoint? {
        let parts = text.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let latitude = Double(parts[0].trimmingCharacters(in: .whitespaces)),
              let longitude = Double(parts[1].trimmingCharacters(in: .whitespaces))
        else {
            return nil
        }
        return validPoint(longitude: longitude, latitude: latitude)
    }

    /// Geohash base-32, which interleaves longitude and latitude bits starting with longitude. The
    /// centre of the cell is the point, which is what Elasticsearch itself resolves a geohash to.
    private static func geohashForm(_ text: String) -> SpatialPoint? {
        let alphabet = Array("0123456789bcdefghjkmnpqrstuvwxyz")
        let lowered = text.lowercased()
        guard !lowered.isEmpty, lowered.count <= 12 else { return nil }
        var longitude = (min: -180.0, max: 180.0)
        var latitude = (min: -90.0, max: 90.0)
        var evenBit = true
        for character in lowered {
            guard let value = alphabet.firstIndex(of: character) else { return nil }
            for shift in stride(from: 4, through: 0, by: -1) {
                let bit = (value >> shift) & 1
                if evenBit {
                    let mid = (longitude.min + longitude.max) / 2
                    if bit == 1 { longitude.min = mid } else { longitude.max = mid }
                } else {
                    let mid = (latitude.min + latitude.max) / 2
                    if bit == 1 { latitude.min = mid } else { latitude.max = mid }
                }
                evenBit.toggle()
            }
        }
        return validPoint(
            longitude: (longitude.min + longitude.max) / 2,
            latitude: (latitude.min + latitude.max) / 2
        )
    }

    private static func numeric(_ raw: Any?) -> Double? {
        if let value = raw as? Double { return value }
        if let value = raw as? Int { return Double(value) }
        if let value = raw as? NSNumber { return value.doubleValue }
        return nil
    }

    /// A parenthesised tree of numbers, which is all a ClickHouse geo type is on the wire.
    private indirect enum TupleNode {
        case number(Double)
        case group([TupleNode])

        static func parse(_ text: String) -> TupleNode? {
            var bytes = Array(text.utf8)
            var index = 0
            guard let node = parseNode(&bytes, &index) else { return nil }
            skipWhitespace(bytes, &index)
            return index == bytes.count ? node : nil
        }

        private static func parseNode(_ bytes: inout [UInt8], _ index: inout Int) -> TupleNode? {
            skipWhitespace(bytes, &index)
            guard index < bytes.count else { return nil }
            if bytes[index] == 0x28 || bytes[index] == 0x5B {
                let closer: UInt8 = bytes[index] == 0x28 ? 0x29 : 0x5D
                index += 1
                var children: [TupleNode] = []
                skipWhitespace(bytes, &index)
                if index < bytes.count, bytes[index] == closer {
                    index += 1
                    return .group([])
                }
                while true {
                    guard let child = parseNode(&bytes, &index) else { return nil }
                    children.append(child)
                    skipWhitespace(bytes, &index)
                    guard index < bytes.count else { return nil }
                    if bytes[index] == 0x2C {
                        index += 1
                        continue
                    }
                    if bytes[index] == closer {
                        index += 1
                        return .group(children)
                    }
                    return nil
                }
            }
            let start = index
            while index < bytes.count, bytes[index] != 0x2C, bytes[index] != 0x29, bytes[index] != 0x5D {
                index += 1
            }
            let token = String(decoding: bytes[start ..< index], as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
            guard let value = Double(token) else { return nil }
            return .number(value)
        }

        private static func skipWhitespace(_ bytes: [UInt8], _ index: inout Int) {
            while index < bytes.count, bytes[index] == 0x20 || bytes[index] == 0x09 { index += 1 }
        }

        var point: SpatialPoint? {
            guard case .group(let children) = self, children.count == 2,
                  case .number(let x) = children[0], case .number(let y) = children[1]
            else {
                return nil
            }
            return SpatialPoint(x: x, y: y)
        }

        var ring: [SpatialPoint]? {
            guard case .group(let children) = self, !children.isEmpty else { return nil }
            var points: [SpatialPoint] = []
            points.reserveCapacity(children.count)
            for child in children {
                guard let point = child.point else { return nil }
                points.append(point)
            }
            return points
        }

        var polygon: [[SpatialPoint]]? {
            guard case .group(let children) = self, !children.isEmpty else { return nil }
            var rings: [[SpatialPoint]] = []
            rings.reserveCapacity(children.count)
            for child in children {
                guard let ring = child.ring else { return nil }
                rings.append(ring)
            }
            return rings
        }

        /// Shape decides the type, because the wire carries no name: a pair of numbers is a Point,
        /// a list of pairs a Ring, a list of Rings a Polygon, and a list of Polygons a MultiPolygon.
        var geometry: SpatialGeometry? {
            if let point { return .point(point) }
            if let ring { return .polygon(rings: [ring]) }
            if let polygon { return .polygon(rings: polygon) }
            guard case .group(let children) = self, !children.isEmpty else { return nil }
            var polygons: [[[SpatialPoint]]] = []
            polygons.reserveCapacity(children.count)
            for child in children {
                guard let polygon = child.polygon else { return nil }
                polygons.append(polygon)
            }
            return .multiPolygon(polygons)
        }
    }
}
