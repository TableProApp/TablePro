//
//  GeometryFieldPreviewTests.swift
//  TableProTests
//

import Foundation
import TableProGeometry
import Testing

@testable import TablePro

private extension GeometryFieldPreview {
    var reason: Reason? {
        guard case .unavailable(let reason) = self else { return nil }
        return reason
    }

    var caption: String? {
        guard case .drawable(_, let caption) = self else { return nil }
        return caption
    }

    var projection: ResultMapProjection? {
        guard case .drawable(let projection, _) = self else { return nil }
        return projection
    }
}

// An SRID is an identifier, not a quantity, so it is named once here rather than written with the
// thousand separator the lint rule asks of a literal.
// swiftlint:disable number_separator
private let wgs84: Int32 = 4326
private let webMercator: Int32 = 3857
private let britishNationalGrid: Int32 = 27700
// swiftlint:enable number_separator

private func preview(_ text: String, source: GeometryFieldSource = .spatialColumn) -> GeometryFieldPreview {
    GeometryFieldPreview.make(text: text, source: source, state: .value(text))
}

/// What a binary cell is handed to a field as: one character per stored byte.
private func binaryText(hex: String) -> String {
    var bytes: [UInt8] = []
    var rest = Substring(hex)
    while rest.count >= 2 {
        bytes.append(UInt8(rest.prefix(2), radix: 16) ?? 0)
        rest = rest.dropFirst(2)
    }
    return String(data: Data(bytes), encoding: .isoLatin1) ?? ""
}

struct GeometryFieldPreviewTests {
    // MARK: - State

    /// The state is asked before the text, because a NULL field hands the editor empty text and an
    /// empty read would call it unreadable.
    @Test("A field with no single value says which state it is in, whatever the text")
    func stateOutranksTheText() {
        let text = "SRID=4326;POINT(-122.4194 37.7749)"
        let expected: [(state: FieldValueState, reason: GeometryFieldPreview.Reason)] = [
            (.null, .null),
            (.pendingNull, .null),
            (.multipleValues, .multipleValues),
            (.absent, .absent),
            (.pendingRemoval, .absent),
            (.pendingDefault, .absent),
        ]
        for entry in expected {
            let made = GeometryFieldPreview.make(text: text, source: .spatialColumn, state: entry.state)
            #expect(made.reason == entry.reason, "\(entry.state)")
        }
    }

    @Test("The text is what is read, not the value the state carries")
    func pendingTextIsRead() {
        let made = GeometryFieldPreview.make(
            text: "SRID=4326;POINT(1 2)",
            source: .spatialColumn,
            state: .value("not a geometry")
        )
        #expect(made.projection?.shapes.count == 1)
    }

    // MARK: - Reasons

    @Test("Text no reader knows is unreadable")
    func unreadableText() {
        #expect(preview("hello world").reason == .unreadable)
        #expect(preview("").reason == .unreadable)
        #expect(preview("SRID=4326;POINT(-122.4194 37.77").reason == .unreadable)
        #expect(preview("MDSYS.SDO_GEOMETRY(2001,4326,MDSYS.SDO_POINT_TYPE(-122.4,37.8,NULL),NULL,NULL)").reason == .unreadable)
    }

    @Test("A type the map cannot draw is named")
    func unsupportedTypeIsNamed() {
        let made = preview("CIRCULARSTRING(0 0,1 1,2 0)")
        #expect(made.reason == .unsupportedType("CIRCULARSTRING"))
        #expect(made.reason?.message.contains("CIRCULARSTRING") == true)
    }

    /// An empty geometry has no coordinates, so asking the coordinate system first told it that its
    /// coordinates were out of range.
    @Test("An empty geometry is called empty before its coordinate system is asked")
    func emptyGeometry() {
        #expect(preview("POINT EMPTY").reason == .empty)
        #expect(preview("GEOMETRYCOLLECTION EMPTY").reason == .empty)
        #expect(preview("SRID=27700;POINT EMPTY").reason == .empty)
    }

    @Test("An SRID the map cannot place is named")
    func unsupportedSRIDIsNamed() {
        let made = preview("SRID=27700;POINT(530000 180000)")
        #expect(made.reason == .unsupportedSRID(britishNationalGrid))
        #expect(made.reason?.message.contains("27700") == true)
        #expect(made.reason?.message.contains("projected coordinate system") == false)
    }

    @Test("No SRID and coordinates outside longitude and latitude cannot be placed")
    func noSRIDOutOfRange() {
        #expect(preview("POINT(530000 180000)").reason == .noSRIDOutOfRange)
    }

    /// Swapped axes are the classic case: the value reads and names a supported SRID, and latitude
    /// -122 is not on the map. It is not empty and it is not past the map's edge.
    @Test("A value that reads in a supported system and still draws nothing says so")
    func nothingDrawable() {
        #expect(preview("SRID=4326;POINT(37.7749 -122.4194)").reason == .nothingDrawable)
        #expect(preview("SRID=4326;LINESTRING(1 1)").reason == .nothingDrawable)
        #expect(preview("[(0,0),(10,10)]").reason == .nothingDrawable)
    }

    @Test("A geometry wholly past latitude 85.05 has no map to sit on")
    func pastTheMapEdge() {
        #expect(preview("SRID=4326;POINT(10 86)").reason == .pastMapLatitude)
        #expect(preview("SRID=4326;POINT(10 85.05)").reason == .pastMapLatitude)
        #expect(preview("SRID=4326;POINT(10 -86)").reason == .pastMapLatitude)
        #expect(preview("SRID=4326;LINESTRING(10 86,20 87)").reason == .pastMapLatitude)
        #expect(preview("SRID=4326;MULTIPOINT(10 86,10 -86)").reason == .pastMapLatitude)
    }

    @Test("A geometry that reaches inside latitude 85.05 is drawn")
    func insideTheMapEdge() {
        #expect(preview("SRID=4326;POINT(10 85.04)").projection?.shapes.count == 1)
        #expect(preview("SRID=4326;MULTIPOINT(10 86,10 10)").projection?.shapes.count == 2)
        /// Each end is past an edge, but the line between them crosses the whole map.
        #expect(preview("SRID=4326;LINESTRING(10 86,10 -86)").projection?.shapes.count == 1)
    }

    @Test("A geometry past the budget is refused whole rather than drawn in part")
    func overBudget() {
        let points = (0 ..< 40).map { "\(-122.0 + Double($0) / 100) 37.5" }.joined(separator: ",")
        let text = "MULTIPOINT(\(points))"
        let capped = GeometryFieldPreview.make(
            text: text,
            source: .spatialColumn,
            state: .value(text),
            budget: SpatialResultProjector.ShapeBudget(shapes: 5, vertices: 1_000)
        )
        #expect(capped.reason == .overBudget)

        let fitting = GeometryFieldPreview.make(
            text: text,
            source: .spatialColumn,
            state: .value(text),
            budget: SpatialResultProjector.ShapeBudget(shapes: 40, vertices: 40)
        )
        #expect(fitting.projection?.shapes.count == 40)
        #expect(preview(text).projection?.shapes.count == 40)
    }

    @Test("Every reason has its own sentence")
    func everyReasonHasItsOwnSentence() {
        let reasons: [GeometryFieldPreview.Reason] = [
            .null, .multipleValues, .absent, .unreadable, .unsupportedType("TIN"), .empty,
            .unsupportedSRID(britishNationalGrid), .noSRIDOutOfRange, .nothingDrawable, .pastMapLatitude,
            .overBudget,
        ]
        let messages = reasons.map(\.message)
        #expect(messages.allSatisfy { !$0.isEmpty })
        #expect(Set(messages).count == reasons.count)
        /// The inspector pane bans the middle dot as a separator, and these sentences are drawn there.
        #expect(messages.allSatisfy { !$0.contains("\u{00B7}") })
    }

    // MARK: - Drawable

    @Test("A point is drawn with its type, its SRID and its coordinate in the caption")
    func pointCaption() {
        let made = preview("SRID=4326;POINT(-122.4194 37.7749)")
        #expect(made.projection?.shapes.count == 1)
        #expect(made.projection?.shapes.first?.kind == .point)
        let caption = made.caption ?? ""
        #expect(caption.contains("Point"))
        #expect(caption.contains("4326"))
        #expect(caption.contains("37.77490"))
        #expect(caption.contains("-122.41940"))
        #expect(!caption.contains("\u{00B7}"))
    }

    /// The caption reports degrees, which is what the marker is placed at, not the stored metres.
    @Test("A Web Mercator point is captioned with the SRID it carries and the degrees it lands on")
    func webMercatorCaption() {
        let caption = preview("SRID=3857;POINT(-13627665.271218073 4547675.354340557)").caption ?? ""
        #expect(caption.contains("3857"))
        #expect(caption.contains("37.77490"))
        #expect(caption.contains("-122.41940"))
    }

    @Test("A value with no SRID is captioned without one")
    func noSRIDCaption() {
        let named = preview("SRID=4326;POLYGON((0 0,4 0,4 4,0 4,0 0))").caption ?? ""
        let unnamed = preview("POLYGON((0 0,4 0,4 4,0 4,0 0))").caption ?? ""
        #expect(named.contains("Polygon"))
        #expect(named.contains("4326"))
        #expect(unnamed.contains("Polygon"))
        #expect(!unnamed.contains("4326"))
        #expect(!unnamed.isEmpty)
    }

    @Test("Only a single point gets a coordinate in the caption")
    func coordinateOnlyForOnePoint() {
        let polygon = preview("SRID=4326;POLYGON((0 0,4 0,4 4,0 4,0 0),(1 1,2 1,2 2,1 2,1 1))")
        #expect(polygon.projection?.shapes.first?.rings.count == 2)
        #expect(polygon.caption?.contains("0.00000") == false)

        let twoPoints = preview("SRID=4326;MULTIPOINT(1.5 2.5,3.5 4.5)")
        #expect(twoPoints.projection?.shapes.count == 2)
        #expect(twoPoints.caption?.contains("2.50000") == false)

        let onePoint = preview("SRID=4326;MULTIPOINT(1.5 2.5)")
        #expect(onePoint.caption?.contains("MultiPoint") == true)
        #expect(onePoint.caption?.contains("2.50000") == true)
    }

    /// The value used to be drawn in part with nothing said, which reads as the whole of it.
    @Test("Parts that cannot be drawn are named in the caption")
    func droppedPartsAreNamed() {
        let whole = preview("SRID=4326;MULTIPOLYGON(((10 10,11 10,11 11,10 10)))")
        let partial = preview(
            "SRID=4326;MULTIPOLYGON(((179 50,181 50,181 51,179 50)),((10 10,11 10,11 11,10 10)))"
        )
        #expect(partial.projection?.shapes.count == 1)
        #expect(partial.projection?.diagnostics.droppedParts == 1)
        #expect(whole.projection?.diagnostics.droppedParts == 0)

        let wholeCaption = whole.caption ?? ""
        let partialCaption = partial.caption ?? ""
        #expect(!wholeCaption.isEmpty)
        #expect(partialCaption.hasPrefix(wholeCaption))
        #expect(partialCaption.count > wholeCaption.count)
    }

    /// The count sits inside the sentence, so one left-out part needs a sentence of its own.
    @Test("One left-out part is not called parts")
    func oneDroppedPartIsSingular() {
        let whole = preview("SRID=4326;MULTIPOLYGON(((10 10,11 10,11 11,10 10)))").caption ?? ""
        let partial = preview(
            "SRID=4326;MULTIPOLYGON(((179 50,181 50,181 51,179 50)),((10 10,11 10,11 11,10 10)))"
        ).caption ?? ""
        #expect(!whole.isEmpty)
        #expect(partial.hasPrefix(whole))
        let sentence = String(partial.dropFirst(whole.count))
        #expect(sentence.contains("1"))
        #expect(!sentence.contains("1 parts"))
        #expect(!sentence.contains(" are "))
    }

    @Test("The dropped-parts sentence carries the count")
    func droppedPartsCount() {
        let made = preview("SRID=4326;MULTIPOINT(1 2,500 2,501 2,502 2,503 2,504 2,505 2,506 2)")
        #expect(made.projection?.shapes.count == 1)
        #expect(made.projection?.diagnostics.droppedParts == 7)
        #expect(made.caption?.contains("7") == true)
    }

    @Test("Every shape of a field carries the one fixed row")
    func shapesShareOneRow() {
        let made = preview("GEOMETRYCOLLECTION(POINT(1 2),LINESTRING(0 0,1 1),POLYGON((0 0,4 0,4 4,0 0)))")
        let shapes = made.projection?.shapes ?? []
        let kinds = shapes.map(\.kind)
        #expect(kinds == [.point, .polyline, .polygon])
        #expect(shapes.allSatisfy { $0.rowID == GeometryFieldPreview.rowID })
    }

    @Test("A drawable preview reports one row and what it drew")
    func drawableDiagnostics() {
        let diagnostics = preview("SRID=3857;POINT(-13627665.271218073 4547675.354340557)").projection?.diagnostics
        #expect(diagnostics?.drawnRows == 1)
        #expect(diagnostics?.drawnShapes == 1)
        #expect(diagnostics?.drawnSRID == webMercator)
        #expect(diagnostics?.projectability == .webMercator)
    }

    // MARK: - Sources

    @Test("A JSON column is read as GeoJSON and nothing wider")
    func jsonColumnReadsGeoJSONOnly() {
        let geoJSON = preview(#"{"type":"Point","coordinates":[-122.4194,37.7749]}"#, source: .jsonColumn)
        #expect(geoJSON.projection?.shapes.count == 1)
        #expect(geoJSON.projection?.diagnostics.drawnSRID == wgs84)

        #expect(preview("[10,20]", source: .jsonColumn).reason == .unreadable)
        #expect(preview(#"{"lat":41.12,"lon":-71.34}"#, source: .jsonColumn).reason == .unreadable)
        #expect(preview(#"{"type":"user","name":"x"}"#, source: .jsonColumn).reason == .unreadable)
    }

    /// A spatial column can hold JSON-shaped text that is not GeoJSON, and the result map draws it.
    @Test("A spatial column keeps the wide reader for JSON-shaped values")
    func spatialColumnReadsEveryShorthand() {
        #expect(preview(#"{"lat":41.12,"lon":-71.34}"#).projection?.shapes.count == 1)
        #expect(preview("(-122.4194,37.7749)").projection?.shapes.count == 1)
        #expect(preview(#"{"type":"Point","coordinates":[-122.4194,37.7749]}"#).projection?.shapes.count == 1)
        #expect(preview("0101000020E610000050FC1873D79A5EC0D0D556EC2FE34240").projection?.shapes.count == 1)
    }

    /// The bytes arrive as one character each. Read as text they are not geometry, which is what
    /// the field showed for a blob the result map drew.
    @Test("A binary value is read from its stored bytes")
    func binaryReadsStoredBytes() {
        let wkb = binaryText(hex: "0101000000000000000000F03F0000000000000040")
        #expect(preview(wkb, source: .spatialColumn).reason == .unreadable)

        let made = preview(wkb, source: .binary)
        #expect(made.projection?.shapes.first?.rings == [[GeographicCoordinate(longitude: 1, latitude: 2)]])

        let ewkb = binaryText(hex: "0101000020E610000050FC1873D79A5EC0D0D556EC2FE34240")
        #expect(preview(ewkb, source: .binary).projection?.diagnostics.drawnSRID == wgs84)
    }

    @Test("Bytes that are not WKB are unreadable")
    func binaryThatIsNotWKB() {
        #expect(preview("", source: .binary).reason == .unreadable)
        #expect(preview(binaryText(hex: "47500003E6100000"), source: .binary).reason == .unreadable)
    }

    /// The hex of a short blob is a valid geohash, so the text readers would place it as a point.
    @Test("A blob of a few bytes is not read as a geohash")
    func shortBlobIsNotAGeohash() {
        #expect(preview(binaryText(hex: "1234"), source: .binary).reason == .unreadable)
        #expect(preview(binaryText(hex: "12345678"), source: .binary).reason == .unreadable)
    }
}
