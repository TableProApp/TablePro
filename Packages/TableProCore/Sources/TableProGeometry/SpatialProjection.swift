import Foundation

/// A longitude and latitude in WGS84 degrees, which is the only thing a map can draw.
public struct GeographicCoordinate: Equatable, Sendable {
    public let longitude: Double
    public let latitude: Double

    public init(longitude: Double, latitude: Double) {
        self.longitude = longitude
        self.latitude = latitude
    }

    /// The range MapKit accepts. Outside it `MKMapPoint(coordinate)` returns the sentinel
    /// `(-1, -1)` rather than wrapping (measured), which is garbage outside `MKMapRectWorld` and
    /// destroys an extent fold, so every coordinate is checked before a shape is built.
    public var isValid: Bool {
        longitude.isFinite && latitude.isFinite
            && longitude >= -180 && longitude <= 180
            && latitude >= -90 && latitude <= 90
    }
}

/// How, or whether, a coordinate system's values can reach a map.
public enum SpatialProjectability: Equatable, Sendable {
    /// Already longitude and latitude in degrees. Drawn as-is.
    case geographic
    /// Spherical Mercator metres. Inverted by a closed-form formula, no projection library.
    case webMercator
    /// No SRID was carried and the values fit the longitude/latitude envelope, so they are drawn
    /// as degrees and the pane says it is assuming that.
    case assumedGeographic
    /// A projected or unknown system that cannot be turned into degrees here.
    case unsupported(srid: Int32?)
}

public enum SpatialProjection {
    /// Geographic systems whose coordinates are already WGS84-compatible degrees.
    ///
    /// 4269 is NAD83: its datum shift against WGS84 is under a metre, far below one tile pixel at
    /// any zoom a map offers. 4979 is WGS84 in three dimensions, whose horizontal components are
    /// identical to 4326.
    public static let geographicSRIDs: Set<Int32> = [4326, 4269, 4979]

    /// The spherical Mercator aliases. 900913 is the original Google code, 102100 and 102113 are
    /// the Esri ones, 3785 the deprecated EPSG code, and 3857 the one that stuck.
    public static let webMercatorSRIDs: Set<Int32> = [3857, 900_913, 102_100, 102_113, 3785]

    private static let earthRadius = 6_378_137.0

    public static func projectability(srid: Int32?, geometry: SpatialGeometry) -> SpatialProjectability {
        if let srid {
            if geographicSRIDs.contains(srid) { return .geographic }
            if webMercatorSRIDs.contains(srid) { return .webMercator }
            return .unsupported(srid: srid)
        }
        /// PostGIS writes no prefix for SRID 0 and MySQL stores a literal 0, and both mean
        /// "nobody said". Degrees are the overwhelmingly common case for such a column, so the
        /// values get to speak: if every one of them fits the envelope they are drawn, and the
        /// pane says the assumption out loud.
        return fitsGeographicEnvelope(geometry) ? .assumedGeographic : .unsupported(srid: nil)
    }

    public static func fitsGeographicEnvelope(_ geometry: SpatialGeometry) -> Bool {
        var sawPoint = false
        for point in geometry.allPoints {
            guard point.x.isFinite, point.y.isFinite,
                  point.x >= -180, point.x <= 180,
                  point.y >= -90, point.y <= 90
            else {
                return false
            }
            sawPoint = true
        }
        return sawPoint
    }

    /// Turns one stored coordinate into degrees, or reports that it cannot be drawn.
    ///
    /// Stored order is (x, y) = (longitude, latitude) for every dialect TablePro reads, including
    /// MySQL's, whose WKB is longitude-first even though `ST_AsText` prints latitude first for
    /// SRID 4326 (measured byte-identical on MySQL 8.4.11 and MariaDB 12.3.3).
    public static func project(
        _ point: SpatialPoint,
        using projectability: SpatialProjectability
    ) -> GeographicCoordinate? {
        let coordinate: GeographicCoordinate
        switch projectability {
        case .geographic, .assumedGeographic:
            coordinate = GeographicCoordinate(longitude: point.x, latitude: point.y)
        case .webMercator:
            guard point.x.isFinite, point.y.isFinite else { return nil }
            let longitude = point.x / earthRadius * 180 / .pi
            let latitude = (2 * atan(exp(point.y / earthRadius)) - .pi / 2) * 180 / .pi
            coordinate = GeographicCoordinate(longitude: longitude, latitude: latitude)
        case .unsupported:
            return nil
        }
        return coordinate.isValid ? coordinate : nil
    }
}
