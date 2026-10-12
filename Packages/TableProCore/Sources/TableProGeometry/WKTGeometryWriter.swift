import Foundation

/// Renders a geometry back to EWKT.
///
/// The output format is the one TablePro's MySQL driver has always shown, kept exactly: a whole
/// number prints with one decimal place, ordinates are separated by a space and elements by a
/// comma and a space. Changing it would rewrite what every MySQL geometry cell in the app looks
/// like for no reason the reader asked for.
///
/// The `SRID=n;` prefix follows PostGIS's `ST_AsEWKT`: present only when there is an SRID to name.
public enum WKTGeometryWriter {
    public static func string(from value: SpatialValue) -> String {
        guard let srid = value.srid else { return string(from: value.geometry) }
        return "SRID=\(srid);" + string(from: value.geometry)
    }

    /// An empty container takes the `EMPTY` keyword rather than empty parentheses. `POLYGON()` and
    /// `GEOMETRYCOLLECTION()` are not legal WKT, and MySQL emitting the latter is exactly the value
    /// that could not be read back.
    public static func string(from geometry: SpatialGeometry) -> String {
        switch geometry {
        case .empty:
            return "GEOMETRYCOLLECTION EMPTY"
        case .point(let point):
            return "POINT(\(coordinate(point)))"
        case .lineString(let points):
            return points.isEmpty ? "LINESTRING EMPTY" : "LINESTRING(\(run(points)))"
        case .polygon(let rings):
            return rings.isEmpty ? "POLYGON EMPTY" : "POLYGON(\(ringList(rings)))"
        case .multiPoint(let points):
            return points.isEmpty ? "MULTIPOINT EMPTY" : "MULTIPOINT(\(run(points)))"
        case .multiLineString(let lines):
            return lines.isEmpty ? "MULTILINESTRING EMPTY" : "MULTILINESTRING(\(ringList(lines)))"
        case .multiPolygon(let polygons):
            guard !polygons.isEmpty else { return "MULTIPOLYGON EMPTY" }
            let bodies = polygons.map { "(\(ringList($0)))" }
            return "MULTIPOLYGON(\(bodies.joined(separator: ", ")))"
        case .collection(let children):
            guard !children.isEmpty else { return "GEOMETRYCOLLECTION EMPTY" }
            let bodies = children.map { string(from: $0) }
            return "GEOMETRYCOLLECTION(\(bodies.joined(separator: ", ")))"
        }
    }

    private static func ringList(_ rings: [[SpatialPoint]]) -> String {
        rings.map { "(\(run($0)))" }.joined(separator: ", ")
    }

    private static func run(_ points: [SpatialPoint]) -> String {
        points.map(coordinate).joined(separator: ", ")
    }

    private static func coordinate(_ point: SpatialPoint) -> String {
        "\(number(point.x)) \(number(point.y))"
    }

    private static func number(_ value: Double) -> String {
        guard value.isFinite else { return "NaN" }
        if value == value.rounded(), abs(value) < 1e15 {
            return String(format: "%.1f", value)
        }
        return String(format: "%.15g", value)
    }
}
