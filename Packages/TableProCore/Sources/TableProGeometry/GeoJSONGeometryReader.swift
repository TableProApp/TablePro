import Foundation

/// Reads the GeoJSON that MongoDB, Snowflake and Elasticsearch hand over.
///
/// RFC 7946 fixes two things this reader relies on: coordinates are `[longitude, latitude]`, and
/// the coordinate reference system is always WGS84, so a decoded value reports SRID 4326 rather
/// than nil. A third position is altitude and is dropped, exactly as `MKGeoJSONDecoder` does.
///
/// `MKGeoJSONDecoder` covers this format natively and is used in preference where a whole document
/// is being read, but it rejects an entire document when one coordinate is out of range
/// (`MKErrorDomain` code 6, measured), which would blank a result over a single bad row. Reading
/// per value keeps one bad row to itself.
public enum GeoJSONGeometryReader {
    public static func read(_ text: String) -> Result<SpatialValue, SpatialReadFailure> {
        guard let data = text.data(using: .utf8) else { return .failure(.notGeometry) }
        return read(data)
    }

    public static func read(_ data: Data) -> Result<SpatialValue, SpatialReadFailure> {
        guard let root = try? JSONSerialization.jsonObject(with: data),
              let object = root as? [String: Any]
        else {
            return .failure(.notGeometry)
        }
        guard let geometry = geometry(from: object, depth: 1) else { return .failure(.notGeometry) }
        return .success(SpatialValue(srid: 4326, geometry: geometry))
    }

    public static func looksLikeGeoJSON(_ text: String) -> Bool {
        guard let first = text.first(where: { !$0.isWhitespace }), first == "{" else { return false }
        return text.contains("\"type\"") && (text.contains("\"coordinates\"")
            || text.contains("\"geometry\"")
            || text.contains("\"geometries\"")
            || text.contains("\"features\""))
    }

    private static func geometry(from object: [String: Any], depth: Int) -> SpatialGeometry? {
        guard depth <= SpatialLimits.maximumNestingDepth else { return nil }
        guard let type = object["type"] as? String else { return nil }
        switch type {
        case "Feature":
            guard let nested = object["geometry"] as? [String: Any] else { return nil }
            return geometry(from: nested, depth: depth + 1)
        case "FeatureCollection":
            guard let features = object["features"] as? [[String: Any]] else { return nil }
            let children = features.compactMap { geometry(from: $0, depth: depth + 1) }
            return children.count == 1 ? children[0] : .collection(children)
        case "GeometryCollection":
            guard let members = object["geometries"] as? [[String: Any]] else { return nil }
            return .collection(members.compactMap { geometry(from: $0, depth: depth + 1) })
        case "Point":
            guard let point = position(object["coordinates"]) else { return nil }
            return .point(point)
        case "MultiPoint":
            guard let points = positions(object["coordinates"]) else { return nil }
            return .multiPoint(points)
        case "LineString":
            guard let points = positions(object["coordinates"]) else { return nil }
            return .lineString(points)
        case "MultiLineString":
            guard let lines = positionRings(object["coordinates"]) else { return nil }
            return .multiLineString(lines)
        case "Polygon":
            guard let rings = positionRings(object["coordinates"]) else { return nil }
            return .polygon(rings: rings)
        case "MultiPolygon":
            guard let raw = object["coordinates"] as? [Any] else { return nil }
            var polygons: [[[SpatialPoint]]] = []
            polygons.reserveCapacity(raw.count)
            for entry in raw {
                guard let rings = positionRings(entry) else { return nil }
                polygons.append(rings)
            }
            return .multiPolygon(polygons)
        default:
            return nil
        }
    }

    private static func position(_ raw: Any?) -> SpatialPoint? {
        guard let values = raw as? [Any], values.count >= 2,
              let x = double(values[0]), let y = double(values[1])
        else {
            return nil
        }
        return SpatialPoint(x: x, y: y)
    }

    private static func positions(_ raw: Any?) -> [SpatialPoint]? {
        guard let entries = raw as? [Any] else { return nil }
        var points: [SpatialPoint] = []
        points.reserveCapacity(entries.count)
        for entry in entries {
            guard let point = position(entry) else { return nil }
            points.append(point)
        }
        return points
    }

    private static func positionRings(_ raw: Any?) -> [[SpatialPoint]]? {
        guard let entries = raw as? [Any] else { return nil }
        var rings: [[SpatialPoint]] = []
        rings.reserveCapacity(entries.count)
        for entry in entries {
            guard let ring = positions(entry) else { return nil }
            rings.append(ring)
        }
        return rings
    }

    private static func double(_ raw: Any) -> Double? {
        if let value = raw as? Double { return value }
        if let value = raw as? Int { return Double(value) }
        if let value = raw as? NSNumber { return value.doubleValue }
        return nil
    }
}
