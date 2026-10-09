//
//  FieldEditorResolverTests.swift
//  TableProTests
//

import AppKit
import Foundation
@testable import TablePro
import Testing

/// What a binary cell is handed to the inspector as: one character per stored byte.
private func binaryText(hex: String) -> String {
    var bytes: [UInt8] = []
    var rest = Substring(hex)
    while rest.count >= 2 {
        bytes.append(UInt8(rest.prefix(2), radix: 16) ?? 0)
        rest = rest.dropFirst(2)
    }
    return String(data: Data(bytes), encoding: .isoLatin1) ?? ""
}

private enum GeometrySample {
    static let wkbPoint = "0101000000000000000000F03F0000000000000040"
    static let ewkbPoint = "0101000020E6100000000000000000F03F0000000000000040"
    static let geoJsonPoint = #"{"type":"Point","coordinates":[-122.4194,37.7749]}"#
    /// A GeoPackage blob: the `GP` header and SRS id ahead of the same WKB point.
    static let geoPackagePoint = "47500001E6100000" + wkbPoint
    /// A SpatiaLite blob: start byte, byte order, SRID, bounding box, then the point and an end byte.
    static let spatiaLitePoint = "0001E6100000"
        + "000000000000F03F0000000000000040000000000000F03F0000000000000040"
        + "7C01000000000000000000F03F0000000000000040FE"
}

@MainActor
struct FieldEditorResolverTests {
    @Test("JSON column resolves to .json")
    func jsonColumnReturnsJson() {
        let kind = FieldEditorResolver.resolve(
            for: .json(rawType: "JSON"),
            isLongText: false,
            originalValue: "{}"
        )
        #expect(kind == .json)
    }

    @Test("text column with JSON-shaped value resolves to .json")
    func jsonShapedTextReturnsJson() {
        let kind = FieldEditorResolver.resolve(
            for: .text(rawType: "TEXT"),
            isLongText: false,
            originalValue: #"{"k":1}"#
        )
        #expect(kind == .json)
    }

    @Test("text column with PHP-shaped value resolves to .phpSerialized")
    func phpShapedTextReturnsPhpSerialized() {
        let kind = FieldEditorResolver.resolve(
            for: .text(rawType: "TEXT"),
            isLongText: false,
            originalValue: "a:0:{}"
        )
        #expect(kind == .phpSerialized)
    }

    @Test("override .phpSerialized forces .phpSerialized")
    func overridePhpSerializedWins() {
        let kind = FieldEditorResolver.resolve(
            for: .text(rawType: "TEXT"),
            isLongText: false,
            originalValue: "not php",
            displayFormatOverride: .phpSerialized
        )
        #expect(kind == .phpSerialized)
    }

    @Test("a stored value with a newline needs the multi-line editor whatever the column type says")
    func newlineInVarcharReturnsMultiLine() {
        let kind = FieldEditorResolver.resolve(
            for: .text(rawType: "VARCHAR(255)"),
            isLongText: false,
            originalValue: "first line\nsecond line"
        )
        #expect(kind == .multiLine)
    }

    @Test("a long single-line value needs the multi-line editor")
    func longVarcharValueReturnsMultiLine() {
        let kind = FieldEditorResolver.resolve(
            for: .text(rawType: "VARCHAR(10000)"),
            isLongText: false,
            originalValue: String(repeating: "a", count: 5_000)
        )
        #expect(kind == .multiLine)
    }

    @Test("NCLOB and VARCHAR(MAX) route on the value, which the exact-match type list never covered")
    func longValueRoutesForTypesIsLongTextMisses() {
        let long = String(repeating: "a", count: 20_000)
        #expect(ColumnType.text(rawType: "NCLOB").isLongText == false)
        #expect(ColumnType.text(rawType: "nvarchar(max)").isLongText == false)
        #expect(ColumnType.text(rawType: "Nullable(String)").isLongText == false)
        for raw in ["NCLOB", "nvarchar(max)", "Nullable(String)"] {
            let type = ColumnType.text(rawType: raw)
            #expect(FieldEditorResolver.resolve(for: type, isLongText: type.isLongText, originalValue: long) == .multiLine)
        }
    }

    @Test("a short scalar keeps the single-line field AppKit intends for it")
    func shortVarcharStaysSingleLine() {
        let kind = FieldEditorResolver.resolve(
            for: .text(rawType: "VARCHAR(255)"),
            isLongText: false,
            originalValue: "hello"
        )
        #expect(kind == .singleLine)
    }

    @Test("an empty long-text column still opens the multi-line editor")
    func emptyLongTextColumnStaysMultiLine() {
        let kind = FieldEditorResolver.resolve(
            for: .text(rawType: "TEXT"),
            isLongText: true,
            originalValue: ""
        )
        #expect(kind == .multiLine)
    }

    @Test("a NULL value in a short column stays single-line")
    func nullShortValueStaysSingleLine() {
        let kind = FieldEditorResolver.resolve(
            for: .text(rawType: "VARCHAR(255)"),
            isLongText: false,
            originalValue: nil
        )
        #expect(kind == .singleLine)
    }

    @Test("a value right at the threshold stays single-line and one past it does not")
    func thresholdBoundary() {
        let type = ColumnType.text(rawType: "VARCHAR(255)")
        let atLimit = String(repeating: "a", count: FieldEditorResolver.multiLineValueThreshold)
        let overLimit = String(repeating: "a", count: FieldEditorResolver.multiLineValueThreshold + 1)
        #expect(FieldEditorResolver.resolve(for: type, isLongText: false, originalValue: atLimit) == .singleLine)
        #expect(FieldEditorResolver.resolve(for: type, isLongText: false, originalValue: overLimit) == .multiLine)
    }

    @Test("a long JSON value still opens the JSON editor rather than the plain text one")
    func longJsonValueStillResolvesJson() {
        let json = "{\"k\":\"" + String(repeating: "a", count: 5_000) + "\"}"
        let kind = FieldEditorResolver.resolve(
            for: .text(rawType: "TEXT"),
            isLongText: true,
            originalValue: json
        )
        #expect(kind == .json)
    }

    @Test("a long value in a boolean column still opens the picker")
    func longValueInBooleanColumnStillResolvesPicker() {
        let kind = FieldEditorResolver.resolve(
            for: .boolean(rawType: "TINYINT(1)"),
            isLongText: false,
            originalValue: String(repeating: "1", count: 5_000)
        )
        #expect(kind == .boolean)
    }

    @Test("override .json forces .json on non-JSON text")
    func overrideJsonWins() {
        let kind = FieldEditorResolver.resolve(
            for: .text(rawType: "TEXT"),
            isLongText: false,
            originalValue: "plain text",
            displayFormatOverride: .json
        )
        #expect(kind == .json)
    }

    @Test("override .raw skips structured detection for PHP")
    func overrideRawSkipsPhp() {
        let kind = FieldEditorResolver.resolve(
            for: .text(rawType: "TEXT"),
            isLongText: false,
            originalValue: "a:0:{}",
            displayFormatOverride: .raw
        )
        #expect(kind != .phpSerialized)
    }

    @Test("boolean column resolves to .boolean")
    func booleanColumn() {
        let kind = FieldEditorResolver.resolve(
            for: .boolean(rawType: "BOOL"),
            isLongText: false,
            originalValue: "1"
        )
        #expect(kind == .boolean)
    }

    @Test("long text resolves to .multiLine")
    func longTextMultiLine() {
        let kind = FieldEditorResolver.resolve(
            for: .text(rawType: "TEXT"),
            isLongText: true,
            originalValue: "long content"
        )
        #expect(kind == .multiLine)
    }

    @Test("short plain text resolves to .singleLine")
    func plainSingleLine() {
        let kind = FieldEditorResolver.resolve(
            for: .text(rawType: "VARCHAR"),
            isLongText: false,
            originalValue: "short"
        )
        #expect(kind == .singleLine)
    }

    // MARK: - Geometry

    private func geometry(_ textEditor: GeometryTextEditor, _ source: GeometryFieldSource) -> FieldEditorKind {
        .geometry(GeometryFieldDescriptor(textEditor: textEditor, source: source))
    }

    private func resolveSpatial(_ value: String?, isBinaryValue: Bool = false) -> FieldEditorKind {
        FieldEditorResolver.resolve(
            for: .spatial(rawType: "GEOMETRY"),
            isLongText: false,
            originalValue: value,
            isBinaryValue: isBinaryValue
        )
    }

    private func resolveJson(_ value: String?) -> FieldEditorKind {
        FieldEditorResolver.resolve(for: .json(rawType: "JSON"), isLongText: false, originalValue: value)
    }

    @Test("WKT in a spatial column resolves to the geometry field over the text editor")
    func spatialWktResolvesToGeometry() {
        let values = [
            "POINT(1 2)",
            "POINT (1 2)",
            "SRID=4326;POINT(-122.4194 37.7749)",
            "SRID=4326;POLYGON((0 0,10 0,10 10,0 10,0 0))",
            "(-122.4194,37.7749)"
        ]
        for value in values {
            #expect(resolveSpatial(value) == geometry(.multiLine, .spatialColumn), "\(value)")
        }
    }

    /// PostgreSQL hands the raw EWKB hex over as text when its `ST_AsEWKT` rewrite fails.
    @Test("EWKB hex text in a spatial column resolves to the geometry field")
    func spatialEwkbHexTextResolvesToGeometry() {
        #expect(resolveSpatial(GeometrySample.ewkbPoint) == geometry(.multiLine, .spatialColumn))
        #expect(resolveSpatial(GeometrySample.wkbPoint) == geometry(.multiLine, .spatialColumn))
    }

    /// The JSON rule used to answer first, so a spatial column holding GeoJSON was a JSON field
    /// and nothing downstream knew it was a geometry.
    @Test("JSON-shaped geometry in a spatial column is a geometry field over the JSON editor")
    func spatialJsonShapedValueKeepsTheJsonEditor() {
        let values = [
            GeometrySample.geoJsonPoint,
            #"{"lat":41.12,"lon":-71.34}"#,
            "[-71.34,41.12]"
        ]
        for value in values {
            #expect(resolveSpatial(value) == geometry(.json, .spatialColumn), "\(value)")
        }
    }

    @Test("A spatial field with no value to read is still a geometry field")
    func nullSpatialIsStillGeometry() {
        #expect(resolveSpatial(nil) == geometry(.multiLine, .spatialColumn))
        #expect(resolveSpatial("") == geometry(.multiLine, .spatialColumn))
    }

    @Test("A type the map names but cannot draw is still a geometry field")
    func unsupportedTypeIsStillGeometry() {
        for value in ["CIRCULARSTRING(0 0,1 1,2 0)", "SRID=4326;CURVEPOLYGONM((0 0 1,1 1 1,2 0 1,0 0 1))"] {
            #expect(resolveSpatial(value) == geometry(.multiLine, .spatialColumn), "\(value)")
        }
    }

    /// SQL Server, Oracle and Teradata send text no reader takes, and MySQL falls back to `0x` hex.
    @Test("Spatial text no reader takes keeps the editor it had")
    func unreadableSpatialTextKeepsItsEditor() {
        #expect(resolveSpatial("0xE61000000101000000000000000000F03F0000000000000040") == .singleLine)
        #expect(resolveSpatial("POINT(1 2") == .singleLine)
        #expect(resolveSpatial("point") == .singleLine)
        #expect(resolveSpatial(#"{"name":"depot","open":true}"#) == .json)
        let objectText = "MDSYS.SDO_GEOMETRY(2001, 4326, MDSYS.SDO_POINT_TYPE(-122.4194, 37.7749, NULL), NULL, NULL)"
        #expect(resolveSpatial(objectText) == .multiLine)
    }

    @Test("WKB bytes in a spatial column resolve to the geometry field over the hex editor")
    func binarySpatialResolvesToGeometry() {
        for hex in [GeometrySample.wkbPoint, GeometrySample.ewkbPoint] {
            #expect(
                resolveSpatial(binaryText(hex: hex), isBinaryValue: true) == geometry(.hex, .binary),
                "\(hex)"
            )
        }
    }

    /// WKB type 8 is CIRCULARSTRING and 10 is CURVEPOLYGON. The reader names the type from the
    /// header, so the Map segment can say which one it cannot draw, as it does for text.
    @Test("WKB of a type the map cannot draw is still a geometry field over the hex editor")
    func unsupportedBinaryTypeIsStillGeometry() {
        let zero = "0000000000000000"
        let one = "000000000000F03F"
        let two = "0000000000000040"
        let curves = [
            "0108000000" + "03000000" + zero + zero + one + one + two + zero,
            "0108000020" + "E6100000",
            "000000000A"
        ]
        for hex in curves {
            #expect(
                resolveSpatial(binaryText(hex: hex), isBinaryValue: true) == geometry(.hex, .binary),
                "\(hex)"
            )
        }
    }

    /// The field was a text field over the Latin-1 spelling of the bytes, where one keystroke
    /// staged that string over the blob.
    @Test("Bytes in a spatial column that are not WKB get the hex editor, never a text field")
    func unreadableBinarySpatialIsHex() {
        let blobs = [
            GeometrySample.geoPackagePoint,
            GeometrySample.spatiaLitePoint,
            "1234",
            "12345678",
            "DEADBEEF00"
        ]
        for hex in blobs {
            #expect(resolveSpatial(binaryText(hex: hex), isBinaryValue: true) == .blobHex, "\(hex)")
        }
        #expect(resolveSpatial("", isBinaryValue: true) == .blobHex)
        #expect(resolveSpatial(nil, isBinaryValue: true) == .blobHex)
    }

    /// The text readers never see a blob: its bytes can spell WKT, and the hex of a short one is a
    /// valid geohash.
    @Test("A binary cell is read as bytes, not as the text its bytes spell")
    func binarySpatialIsNotReadAsText() {
        #expect(resolveSpatial("POINT(1 2)", isBinaryValue: true) == .blobHex)
        #expect(resolveSpatial(GeometrySample.wkbPoint, isBinaryValue: true) == .blobHex)
    }

    @Test("The binary flag changes nothing outside a spatial column")
    func binaryFlagIsScopedToSpatialColumns() {
        let bytes = binaryText(hex: GeometrySample.wkbPoint)
        #expect(
            FieldEditorResolver.resolve(
                for: .blob(rawType: "BLOB"),
                isLongText: false,
                originalValue: bytes,
                isBinaryValue: true
            ) == .blobHex
        )
    }

    @Test("GeoJSON in a JSON column resolves to the geometry field over the JSON editor")
    func geoJsonInJsonColumnResolvesToGeometry() {
        let values = [
            GeometrySample.geoJsonPoint,
            #"{"type":"Polygon","coordinates":[[[0,0],[10,0],[10,10],[0,0]]]}"#,
            #"{"type":"Feature","properties":{"name":"depot"},"geometry":{"type":"Point","coordinates":[1,2]}}"#
        ]
        for value in values {
            #expect(resolveJson(value) == geometry(.json, .jsonColumn), "\(value)")
        }
    }

    /// The sniffing reader takes each of these for a point. A JSON column is held to GeoJSON, or
    /// every pair of numbers and every document with `lat` and `lon` would open on a map.
    @Test("JSON that is not GeoJSON stays a JSON field")
    func jsonThatIsNotGeoJsonStaysJson() {
        let values = [
            "[10,20]",
            "[[1,2],[3,4],[5,6]]",
            #"{"lat":37.7,"lon":-122.4,"city":"SF"}"#,
            #"{"type":"user","coordinates":"none"}"#,
            #"{"type":"Point"}"#,
            "{}"
        ]
        for value in values {
            #expect(resolveJson(value) == .json, "\(value)")
        }
        #expect(resolveJson(nil) == .json)
    }

    @Test("A value that reads as geometry outside a spatial or JSON column keeps its editor")
    func geometryIsGatedOnTheColumn() {
        let text = ColumnType.text(rawType: "TEXT")
        for value in ["test", "POINT(1 2)", "12.5,45.25", GeometrySample.ewkbPoint] {
            #expect(
                FieldEditorResolver.resolve(for: text, isLongText: false, originalValue: value) == .singleLine,
                "\(value)"
            )
        }
        #expect(
            FieldEditorResolver.resolve(for: text, isLongText: false, originalValue: GeometrySample.geoJsonPoint)
                == .json
        )
    }

    @Test("Raw Value suppresses the geometry field the way it suppresses JSON")
    func rawOverrideSkipsGeometry() {
        let kind = FieldEditorResolver.resolve(
            for: .spatial(rawType: "GEOMETRY"),
            isLongText: false,
            originalValue: "POINT(1 2)",
            displayFormatOverride: .raw
        )
        #expect(kind == .singleLine)
    }

    @Test("A field resolved late carries its binary flag to the resolver")
    func fieldCarriesTheBinaryFlag() {
        var field = FieldEditState(
            columnIndex: 0,
            columnName: "geom",
            columnTypeEnum: .spatial(rawType: "POINT"),
            isLongText: false,
            isJson: false,
            originalValue: binaryText(hex: GeometrySample.wkbPoint),
            hasMultipleValues: false,
            pendingValue: nil,
            isPendingNull: false,
            isPendingDefault: false
        )
        #expect(FieldEditorResolver.resolve(field: field) != geometry(.hex, .binary))

        field.isBinaryValue = true
        #expect(FieldEditorResolver.resolve(field: field) == geometry(.hex, .binary))
    }

    // MARK: - Large geometry values

    /// No reader accepts this after any opening, so a large value that still resolves to a
    /// geometry field was classified by how it opens, not read in full.
    private static let unreadableTail = String(repeating: "x", count: 2_000_000)

    @Test("A large spatial value is classified by how it opens")
    func largeSpatialValueIsSniffed() {
        let tail = Self.unreadableTail
        let multiLine = [
            "POINT(" + tail,
            "  \n\tPOINT (" + tail,
            "SRID=4326;" + tail,
            "srid = 3857;MULTIPOLYGON(((" + tail,
            "circularstring(" + tail,
            "CURVEPOLYGONM((" + tail,
            "0101000020E6100000" + String(repeating: "AB", count: 1_000_000),
            "[[(-122.4194,37.7749)," + tail
        ]
        for value in multiLine {
            #expect(resolveSpatial(value) == geometry(.multiLine, .spatialColumn), "\(value.prefix(32))")
        }
        #expect(resolveSpatial(#"{"type":"Polygon","coordinates":"# + tail) == geometry(.json, .spatialColumn))
    }

    @Test("A value at the preview's limit is still read in full")
    func valueAtTheLimitIsRead() {
        let limit = GeometryFieldPreview.synchronousLimit
        let atLimit = "POINT(" + String(repeating: "x", count: limit - 6)
        #expect(resolveSpatial(atLimit) == .multiLine)
        #expect(resolveSpatial(atLimit + "x") == geometry(.multiLine, .spatialColumn))
    }

    @Test("A large spatial value that does not open like geometry keeps its editor")
    func largeSpatialValueThatOpensOtherwiseKeepsItsEditor() {
        let tail = Self.unreadableTail
        let values = [
            "MDSYS.SDO_GEOMETRY(2001, 4326, " + tail,
            "0xE61000000101000000" + String(repeating: "AB", count: 1_000_000),
            "FFFF" + String(repeating: "AB", count: 1_000_000),
            "pointless " + tail,
            "[{\"a\":" + tail
        ]
        for value in values {
            #expect(resolveSpatial(value) == .multiLine, "\(value.prefix(32))")
        }
    }

    @Test("A large binary value is classified by its first byte")
    func largeBinaryValueIsSniffed() {
        let tail = Self.unreadableTail
        #expect(resolveSpatial("\u{01}" + tail, isBinaryValue: true) == geometry(.hex, .binary))
        #expect(resolveSpatial("\u{00}" + tail, isBinaryValue: true) == geometry(.hex, .binary))
        #expect(resolveSpatial(binaryText(hex: "47500001") + tail, isBinaryValue: true) == .blobHex)
    }

    @Test("A large JSON value is a geometry field when its type member names a GeoJSON type")
    func largeJsonValueIsSniffed() {
        let tail = Self.unreadableTail
        let geoJson = [
            #"{"type":"Polygon","coordinates":"# + tail,
            #"{ "type" : "featurecollection", "features": "# + tail,
            #"{"id":7,"properties":{"name":"depot"},"type":"Feature","geometry":"# + tail
        ]
        for value in geoJson {
            #expect(resolveJson(value) == geometry(.json, .jsonColumn), "\(value.prefix(40))")
        }

        let notGeoJson = [
            #"{"type":"user","coordinates":"# + tail,
            #"{"kind":"Point","coordinates":"# + tail,
            #"{"padding":""# + String(repeating: "p", count: 10_000) + #"","type":"Point","coordinates":"# + tail,
            #"[{"type":"Point","coordinates":"# + tail
        ]
        for value in notGeoJson {
            #expect(resolveJson(value) == .json, "\(value.prefix(40))")
        }
    }
}

@MainActor
struct FieldEditorResolverImageTests {
    private func encodedPng() -> Data {
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 4,
            pixelsHigh: 4,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return Data() }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
        NSColor.systemGreen.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        NSGraphicsContext.restoreGraphicsState()
        return representation.representation(using: .png, properties: [:]) ?? Data()
    }

    @Test("SVG markup in a text column resolves to the image editor")
    func svgTextResolvesToImage() {
        let kind = FieldEditorResolver.resolve(
            for: .text(rawType: "TEXT"),
            isLongText: true,
            originalValue: "<svg><rect/></svg>"
        )
        #expect(kind == .image(.svg))
    }

    /// The image branch runs before the blob branch, or a PNG in a BLOB column would only ever be
    /// a hex dump in the inspector while the grid popover drew it.
    @Test("PNG bytes in a blob column resolve to the image editor")
    func pngBlobResolvesToImage() throws {
        let value = try #require(String(data: encodedPng(), encoding: .isoLatin1))
        let kind = FieldEditorResolver.resolve(
            for: .blob(rawType: "BLOB"),
            isLongText: false,
            originalValue: value
        )
        #expect(kind == .image(.raster("public.png")))
    }

    @Test("binary that is not an image still resolves to the hex editor")
    func nonImageBlobStaysHex() {
        let kind = FieldEditorResolver.resolve(
            for: .blob(rawType: "BLOB"),
            isLongText: false,
            originalValue: "\u{0}\u{1}\u{2}\u{3}"
        )
        #expect(kind == .blobHex)
    }

    @Test("Raw Value suppresses image detection the way it suppresses JSON")
    func rawOverrideSuppressesImage() {
        let kind = FieldEditorResolver.resolve(
            for: .text(rawType: "TEXT"),
            isLongText: true,
            originalValue: "<svg><rect/></svg>",
            displayFormatOverride: .raw
        )
        #expect(kind == .multiLine)
    }

    @Test("JSON still wins over image detection")
    func jsonWinsOverImage() {
        let kind = FieldEditorResolver.resolve(
            for: .text(rawType: "TEXT"),
            isLongText: false,
            originalValue: #"{"a":1}"#
        )
        #expect(kind == .json)
    }

    private var jsonArrayType: ColumnType {
        .array(rawType: "jsonb[]", element: .json(rawType: "jsonb"))
    }

    private var textArrayType: ColumnType {
        .array(rawType: "text[]", element: .text(rawType: "text"))
    }

    @Test("A jsonb[] value resolves to the element editor, not the JSON editor")
    func jsonArrayResolvesToElements() {
        let kind = FieldEditorResolver.resolve(
            for: jsonArrayType,
            isLongText: false,
            originalValue: #"{"{\"id\": 1}","{\"id\": 2}"}"#
        )
        #expect(kind == .arrayElements(element: .json, values: []))
    }

    @Test("A scalar array resolves to the element editor too")
    func scalarArrayResolvesToElements() {
        let kind = FieldEditorResolver.resolve(
            for: textArrayType,
            isLongText: false,
            originalValue: "{a,b}"
        )
        #expect(kind == .arrayElements(element: .scalar, values: []))
    }

    /// `jsonb[]` and `jsonb[][]` are one type in PostgreSQL's catalog and any array column may
    /// carry a dimension prefix, so the declared type cannot rule either out on a given row. The
    /// text editor over the raw literal is the lossless fallback, as it is in the grid, and which
    /// text editor is the value's own length talking: both literals here sit under
    /// `multiLineValueThreshold`.
    @Test("A literal the element list cannot represent falls back to the text editor")
    func unrepresentableArrayFallsBackToText() {
        #expect(
            FieldEditorResolver.resolve(
                for: jsonArrayType,
                isLongText: false,
                originalValue: #"{{"{\"id\": 1}"},{"{\"id\": 2}"}}"#
            ) == .singleLine
        )
        #expect(
            FieldEditorResolver.resolve(
                for: textArrayType,
                isLongText: false,
                originalValue: "[0:2]={a,b,c}"
            ) == .singleLine
        )
    }

    /// An engine whose list literal is not PostgreSQL's reaches the same gate and fails it, so the
    /// classifier's engine-blind `[]` rule cannot hand another driver's value to this editor.
    @Test("A list literal from another engine does not reach the element editor")
    func foreignListLiteralFallsBackToText() {
        let kind = FieldEditorResolver.resolve(
            for: textArrayType,
            isLongText: false,
            originalValue: "[a, b]"
        )
        #expect(kind == .singleLine)
    }

    /// The parse is also what scopes the editor to the engines whose arrays are written this way:
    /// the classifier's `[]` rule takes no engine, and a document store's `object[]` classifies the
    /// same, so a field with no literal to read must not be offered a list that commits `{…}`.
    @Test("An array column with no value keeps the plain editor")
    func absentArrayValueKeepsPlainEditor() {
        #expect(
            FieldEditorResolver.resolve(for: jsonArrayType, isLongText: false, originalValue: nil)
                == .singleLine
        )
        #expect(
            FieldEditorResolver.resolve(for: textArrayType, isLongText: false, originalValue: "")
                == .singleLine
        )
    }

    /// The labels arrive separately in `TableRows.columnEnumValues` and are injected into the type
    /// before the inspector resolves it, so they have to reach the element inside the array.
    @Test("An enum array carries its declared labels into the element editor")
    func enumArrayCarriesItsLabels() {
        let labels = ["sad", "ok", "happy"]
        let type = ColumnType
            .array(rawType: "ENUM[]", element: .enumType(rawType: "ENUM", values: nil))
            .withAllowedValues(labels)
        #expect(
            FieldEditorResolver.resolve(for: type, isLongText: false, originalValue: "{happy}")
                == .arrayElements(element: .scalar, values: labels)
        )
    }

    /// An empty array literal is itself valid JSON, so resolving the array before the JSON branch
    /// is what keeps `{}` out of the JSON editor.
    @Test("An empty array opens the element editor rather than the JSON editor")
    func emptyArrayResolvesToElements() {
        let kind = FieldEditorResolver.resolve(
            for: jsonArrayType,
            isLongText: false,
            originalValue: "{}"
        )
        #expect(kind == .arrayElements(element: .json, values: []))
    }
}
