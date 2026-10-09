//
//  GeometryFieldPreview.swift
//  TablePro
//

import Foundation
import TableProGeometry

/// What a geometry field's Map segment shows for one value: the shapes and a caption, or the reason
/// there is no map. Every state has a sentence, so the segment is never blank.
internal enum GeometryFieldPreview: Equatable, Sendable {
    case drawable(projection: ResultMapProjection, caption: String)
    case unavailable(Reason)

    internal enum Reason: Equatable, Sendable {
        case null
        case multipleValues
        case absent
        case unreadable
        case unsupportedType(String)
        case empty
        case unsupportedSRID(Int32)
        case noSRIDOutOfRange
        /// The value reads and its coordinate system is supported, and still no part of it draws.
        case nothingDrawable
        case pastMapLatitude
        case overBudget
    }
}

internal extension GeometryFieldPreview {
    /// A field draws one value, so every shape carries the same row and nothing is selectable.
    static let rowID: RowID = .existing(0)

    /// Past this many UTF-16 units a read leaves the main actor. A point reads in microseconds and
    /// 2.1 MB of WKT in about 10 ms, measured.
    static let synchronousLimit = 50_000

    static func readsSynchronously(_ text: String) -> Bool {
        (text as NSString).length <= synchronousLimit
    }

    static func make(text: String, source: GeometryFieldSource, state: FieldValueState) -> GeometryFieldPreview {
        make(
            text: text,
            source: source,
            state: state,
            budget: SpatialResultProjector.ShapeBudget(
                shapes: SpatialResultProjector.maximumShapes,
                vertices: SpatialResultProjector.maximumVertices
            )
        )
    }

    /// The budget is a parameter so a test can prove the cap without a two-million-vertex value.
    static func make(
        text: String,
        source: GeometryFieldSource,
        state: FieldValueState,
        budget initialBudget: SpatialResultProjector.ShapeBudget
    ) -> GeometryFieldPreview {
        switch state {
        case .value:
            break
        case .null, .pendingNull:
            return .unavailable(.null)
        case .multipleValues:
            return .unavailable(.multipleValues)
        /// A pending DEFAULT has no value to read until it is saved.
        case .absent, .pendingRemoval, .pendingDefault:
            return .unavailable(.absent)
        }

        let value: SpatialValue
        switch read(text, source: source) {
        case .success(let parsed):
            value = parsed
        case .failure(.unsupportedGeometryType(let keyword)):
            return .unavailable(.unsupportedType(keyword))
        case .failure:
            return .unavailable(.unreadable)
        }

        /// Asked before the coordinate system, because an empty geometry has no coordinates and
        /// would otherwise be told it is out of range.
        guard !value.geometry.isEmpty else { return .unavailable(.empty) }

        let projectability = SpatialProjection.projectability(srid: value.srid, geometry: value.geometry)
        if case .unsupported(let srid) = projectability {
            guard let srid else { return .unavailable(.noSRIDOutOfRange) }
            return .unavailable(.unsupportedSRID(srid))
        }

        var budget = initialBudget
        let built = SpatialShapeBuilder.shapes(
            from: value.geometry,
            rowID: rowID,
            projectability: projectability,
            budget: &budget
        )
        /// A result draws what fits and counts the rest. One value drawn in part would pass for the
        /// whole of it, so the field draws all of it or says why not.
        guard !budget.isExhausted else { return .unavailable(.overBudget) }
        guard !built.shapes.isEmpty else { return .unavailable(.nothingDrawable) }
        guard !liesPastTheMapEdge(built.shapes) else { return .unavailable(.pastMapLatitude) }

        var diagnostics = ResultMapDiagnostics()
        diagnostics.consideredRows = 1
        diagnostics.readableRows = 1
        diagnostics.drawnRows = 1
        diagnostics.drawnShapes = built.shapes.count
        diagnostics.projectability = projectability
        diagnostics.drawnSRID = value.srid
        diagnostics.droppedParts = built.droppedParts
        return .drawable(
            projection: ResultMapProjection(shapes: built.shapes, diagnostics: diagnostics),
            caption: caption(for: value, shapes: built.shapes, droppedParts: built.droppedParts)
        )
    }

    /// A binary cell arrives as one character per stored byte, and the bytes are WKB or not geometry.
    /// The text readers never see them: the hex of a blob under five bytes is a valid geohash.
    static func read(_ text: String, source: GeometryFieldSource) -> Result<SpatialValue, SpatialReadFailure> {
        switch source {
        case .spatialColumn:
            return SpatialValueReader.read(text)
        case .jsonColumn:
            return GeoJSONGeometryReader.read(text)
        case .binary:
            let bytes = [UInt8](text.storedBytes)
            guard !bytes.isEmpty else { return .failure(.notGeometry) }
            return WKBGeometryReader.read(bytes: bytes)
        }
    }
}

private extension GeometryFieldPreview {
    /// Where the map ends, measured: a marker at 85.05 degrees or beyond gets no view at all.
    static let mapLatitudeLimit = 85.05

    /// True only when every shape sits wholly beyond one edge. A line from one polar cap to the
    /// other crosses the whole map, so the two edges are never pooled.
    static func liesPastTheMapEdge(_ shapes: [ResultMapShape]) -> Bool {
        shapes.allSatisfy { shape in
            guard let outline = shape.rings.first, !outline.isEmpty else { return false }
            return outline.allSatisfy { $0.latitude >= mapLatitudeLimit }
                || outline.allSatisfy { $0.latitude <= -mapLatitudeLimit }
        }
    }

    static func caption(for value: SpatialValue, shapes: [ResultMapShape], droppedParts: Int) -> String {
        var sentences: [String] = []
        if let srid = value.srid {
            sentences.append(String(
                format: String(localized: "%1$@ in SRID %2$d."),
                value.geometry.typeName,
                Int(srid)
            ))
        } else {
            sentences.append(String(
                format: String(localized: "%@ with no SRID, read as longitude and latitude."),
                value.geometry.typeName
            ))
        }
        if shapes.count == 1, let shape = shapes.first, shape.kind == .point,
           let coordinate = shape.rings.first?.first
        {
            sentences.append(String(
                format: String(localized: "Latitude %1$.5f, longitude %2$.5f."),
                coordinate.latitude,
                coordinate.longitude
            ))
        }
        if droppedParts == 1 {
            sentences.append(String(localized: "1 part of this geometry cannot be drawn and is left out."))
        } else if droppedParts > 1 {
            sentences.append(String(
                format: String(localized: "%d parts of this geometry cannot be drawn and are left out."),
                droppedParts
            ))
        }
        return sentences.joined(separator: " ")
    }
}

internal extension GeometryFieldPreview.Reason {
    var message: String {
        switch self {
        case .null:
            return String(localized: "This field is NULL.")
        case .multipleValues:
            return String(localized: "Select a single row to map this field.")
        case .absent:
            return String(localized: "This row has no value for this field.")
        case .unreadable:
            return String(localized: "This value is not in a format the map can read.")
        case .unsupportedType(let keyword):
            return String(format: String(localized: "The map cannot draw %@."), keyword)
        case .empty:
            return String(localized: "This geometry is empty.")
        case .unsupportedSRID(let srid):
            return String(
                format: String(localized: """
                The map cannot place SRID %d. It reads longitude and latitude, such as SRID 4326, and \
                Web Mercator.
                """),
                Int(srid)
            )
        case .noSRIDOutOfRange:
            return String(localized: """
            This value has no SRID and its coordinates are outside the range of longitude and \
            latitude, so the map cannot place it.
            """)
        case .nothingDrawable:
            return String(localized: """
            Nothing in this geometry can be drawn. Its coordinates are out of range for its \
            coordinate system, or a line or ring has too few points.
            """)
        case .pastMapLatitude:
            return String(localized: "This geometry is past 85 degrees of latitude, where the map ends.")
        case .overBudget:
            return String(localized: "This geometry has more points than the map draws.")
        }
    }
}
