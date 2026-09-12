import Foundation

public struct SpatialPoint: Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// A geometry as the database describes it, in the coordinate system its SRID names.
///
/// Deliberately not MapKit types: the same value has to survive projection, an extent fold and a
/// refusal, and only the drawing layer knows about `CLLocationCoordinate2D`. Z and M ordinates are
/// read so the cursor stays in step with the wire format and then dropped, because MapKit draws on
/// a sphere and has nowhere to put them.
public indirect enum SpatialGeometry: Equatable, Sendable {
    case point(SpatialPoint)
    case lineString([SpatialPoint])
    /// The first ring is the exterior; every later ring is a hole.
    case polygon(rings: [[SpatialPoint]])
    case multiPoint([SpatialPoint])
    case multiLineString([[SpatialPoint]])
    case multiPolygon([[[SpatialPoint]]])
    case collection([SpatialGeometry])
    case empty
}

/// What the engine handed over, with the coordinate system it named.
///
/// `srid` is nil when the value carried none, which is not the same as zero. PostGIS writes no
/// `SRID=` prefix for 0 and MySQL's wire format writes a literal 0, and both mean "unknown" rather
/// than "a coordinate system numbered zero".
public struct SpatialValue: Equatable, Sendable {
    public let srid: Int32?
    public let geometry: SpatialGeometry

    public init(srid: Int32?, geometry: SpatialGeometry) {
        self.srid = srid
        self.geometry = geometry
    }
}

/// Why a cell could not be read as a geometry.
///
/// `unsupportedGeometryType` carries the keyword so the pane can name it. PostGIS hands out
/// `CIRCULARSTRING`, `CURVEPOLYGON` and `TIN` values that no amount of parsing turns into line
/// segments, and a user told "3 shapes could not be drawn" learns nothing; told
/// "CIRCULARSTRING is not supported" they know what to do.
public enum SpatialReadFailure: Error, Equatable, Sendable {
    case notGeometry
    case unsupportedGeometryType(String)
    case malformed
}

public extension SpatialGeometry {
    var isEmpty: Bool {
        switch self {
        case .empty:
            return true
        case .point:
            return false
        case .lineString(let points), .multiPoint(let points):
            return points.isEmpty
        case .polygon(let rings):
            return rings.allSatisfy(\.isEmpty)
        case .multiLineString(let lines):
            return lines.allSatisfy(\.isEmpty)
        case .multiPolygon(let polygons):
            return polygons.allSatisfy { $0.allSatisfy(\.isEmpty) }
        case .collection(let children):
            return children.allSatisfy(\.isEmpty)
        }
    }

    /// Every coordinate in the geometry, in reading order.
    ///
    /// Used for the projectability envelope test and the vertex budget, both of which need the
    /// count and the extremes rather than the structure.
    var allPoints: [SpatialPoint] {
        var out: [SpatialPoint] = []
        collectPoints(into: &out)
        return out
    }

    var pointCount: Int {
        switch self {
        case .empty:
            return 0
        case .point:
            return 1
        case .lineString(let points), .multiPoint(let points):
            return points.count
        case .polygon(let rings):
            return rings.reduce(0) { $0 + $1.count }
        case .multiLineString(let lines):
            return lines.reduce(0) { $0 + $1.count }
        case .multiPolygon(let polygons):
            return polygons.reduce(0) { $0 + $1.reduce(0) { $0 + $1.count } }
        case .collection(let children):
            return children.reduce(0) { $0 + $1.pointCount }
        }
    }

    private func collectPoints(into out: inout [SpatialPoint]) {
        switch self {
        case .empty:
            return
        case .point(let point):
            out.append(point)
        case .lineString(let points), .multiPoint(let points):
            out.append(contentsOf: points)
        case .polygon(let rings):
            for ring in rings { out.append(contentsOf: ring) }
        case .multiLineString(let lines):
            for line in lines { out.append(contentsOf: line) }
        case .multiPolygon(let polygons):
            for polygon in polygons {
                for ring in polygon { out.append(contentsOf: ring) }
            }
        case .collection(let children):
            for child in children { child.collectPoints(into: &out) }
        }
    }
}
