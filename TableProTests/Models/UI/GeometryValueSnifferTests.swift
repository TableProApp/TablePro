//
//  GeometryValueSnifferTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct GeometryValueSnifferTests {
    private static let pastThePrefix = String(repeating: " ", count: GeometryValueSniffer.prefixLength)

    @Test("A spatial column's text is classified by how it opens")
    func spatialTextTable() {
        let cases: [(text: String, expected: GeometryTextEditor?)] = [
            ("POINT(1 2)", .multiLine),
            ("  \n\tPOINT EMPTY", .multiLine),
            ("pointz(1 2 3)", .multiLine),
            ("GEOMCOLLECTION(", .multiLine),
            ("MultiPolygon(((", .multiLine),
            ("SRID=4326;", .multiLine),
            ("srid =0;anything", .multiLine),
            ("CIRCULARSTRING(", .multiLine),
            ("CurvePolygonM((", .multiLine),
            ("TIN(((", .multiLine),
            ("0101000000" + String(repeating: "00", count: 16), .multiLine),
            ("0001" + String(repeating: "ab", count: 8), .multiLine),
            ("0101000020E6100000\n", .multiLine),
            (#"{"type":"Point""#, .json),
            ("{", .json),
            ("[[(-1.5, 2)", .multiLine),
            ("(.5,1)", .multiLine),
            ("[ [ +1", .multiLine),
            ("0201000000" + String(repeating: "00", count: 16), nil),
            ("FF01000000", nil),
            ("01AB", nil),
            ("0101000000 ZZ", nil),
            ("0x0101000000", nil),
            ("SRID", nil),
            ("SRIDX=1;POINT(1 2)", nil),
            ("pointless", nil),
            ("MDSYS.SDO_GEOMETRY(2001, 4326", nil),
            (#"[{"a":1}]"#, nil),
            ("(abc)", nil),
            ("", nil),
            ("   ", nil),
            (Self.pastThePrefix + "POINT(1 2)", nil)
        ]
        for (text, expected) in cases {
            #expect(GeometryValueSniffer.spatialTextEditor(text) == expected, "\(text.prefix(40))")
        }
    }

    @Test("A binary value opens like WKB when its first byte is a byte order")
    func binaryTable() {
        let cases: [(text: String, expected: Bool)] = [
            ("\u{00}\u{00}\u{00}\u{00}\u{01}", true),
            ("\u{01}\u{01}\u{00}\u{00}\u{00}", true),
            ("\u{02}\u{01}", false),
            ("GP\u{00}\u{01}", false),
            ("\u{FF}", false),
            ("", false)
        ]
        for (text, expected) in cases {
            #expect(GeometryValueSniffer.opensWKB(binary: text) == expected, "\(text.debugDescription)")
        }
    }

    @Test("A JSON value opens like GeoJSON when a type member names a GeoJSON type")
    func geoJsonTable() {
        let cases: [(text: String, expected: Bool)] = [
            (#"{"type":"Point","coordinates":"#, true),
            (#"{"type":"point""#, true),
            (#" { "type" : "MultiPolygon""#, true),
            (#"{"properties":{"kind":"x"},"type":"FeatureCollection""#, true),
            (#"{"type":7,"geometry":{"type":"LineString""#, true),
            (#"{"type":"user","coordinates":[1,2]}"#, false),
            (#"{"TYPE":"Point"}"#, false),
            (#"{"name":"type","value":"Point"}"#, false),
            (#"[{"type":"Point"}]"#, false),
            (#"{"type":"Poi"#, false),
            (#"{"pad":""# + Self.pastThePrefix + #"","type":"Point"}"#, false),
            ("{}", false),
            ("", false)
        ]
        for (text, expected) in cases {
            #expect(GeometryValueSniffer.opensGeoJSON(text) == expected, "\(text.prefix(40))")
        }
    }
}
