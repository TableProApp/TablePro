import Foundation
@testable import TableProFirebaseCore
import Testing

@Suite("Firestore values")
struct FirestoreValueTests {
    @Test("Every REST value type decodes")
    func decode() throws {
        let rest = json("""
        {"mapValue": {"fields": {
          "s": {"stringValue": "hi"},
          "i": {"integerValue": "9007199254740993"},
          "d": {"doubleValue": 1.5},
          "nan": {"doubleValue": "NaN"},
          "b": {"booleanValue": true},
          "n": {"nullValue": null},
          "t": {"timestampValue": "2026-10-12T08:00:00.123456Z"},
          "r": {"referenceValue": "projects/demo/databases/(default)/documents/users/alice"},
          "g": {"geoPointValue": {"latitude": 45.5, "longitude": 9.25}},
          "y": {"bytesValue": "aGk="},
          "a": {"arrayValue": {"values": [{"integerValue": "1"}, {"stringValue": "x"}]}},
          "e": {"arrayValue": {}}
        }}}
        """)
        guard case .map(let fields) = try FirestoreValue(rest: rest, documentRoot: testDocumentRoot) else {
            Issue.record("Expected a map")
            return
        }
        #expect(fields["s"] == .string("hi"))
        #expect(fields["i"] == .integer(9_007_199_254_740_993))
        #expect(fields["d"] == .double(1.5))
        if case .double(let value) = fields["nan"] { #expect(value.isNaN) } else { Issue.record("NaN lost") }
        #expect(fields["b"] == .boolean(true))
        #expect(fields["n"] == .null)
        #expect(fields["t"] == .timestamp("2026-10-12T08:00:00.123456Z"))
        #expect(fields["r"] == .reference("users/alice"))
        #expect(fields["g"] == .geoPoint(latitude: 45.5, longitude: 9.25))
        #expect(fields["y"] == .bytes(Data("hi".utf8)))
        #expect(fields["a"] == .array([.integer(1), .string("x")]))
        #expect(fields["e"] == .array([]))
    }

    @Test("Encoding is the inverse of decoding")
    func roundTrip() throws {
        let values: [FirestoreValue] = [
            .null, .boolean(false), .integer(-7), .double(2.25), .timestamp("2026-01-01T00:00:00Z"),
            .string(""), .bytes(Data([0, 255])), .reference("a/b/c/d"), .geoPoint(latitude: -10, longitude: 20),
            .array([.integer(1), .map(["k": .string("v")])]), .map([:])
        ]
        for value in values {
            let decoded = try FirestoreValue(rest: value.rest(documentRoot: testDocumentRoot), documentRoot: testDocumentRoot)
            #expect(decoded == value)
        }
    }

    @Test("Integers go on the wire as strings, references in full")
    func wireShapes() {
        #expect(FirestoreValue.integer(5).rest(documentRoot: testDocumentRoot).text() == #"{"integerValue":"5"}"#)
        #expect(
            FirestoreValue.reference("users/alice").rest(documentRoot: testDocumentRoot).text()
                == #"{"referenceValue":"projects/demo/databases/(default)/documents/users/alice"}"#
        )
        #expect(FirestoreValue.double(.infinity).rest(documentRoot: testDocumentRoot).text() == #"{"doubleValue":"Infinity"}"#)
    }

    @Test("A value with no type or an unknown type is refused")
    func malformed() {
        #expect(throws: FirebaseError.self) { try FirestoreValue(rest: json("{}"), documentRoot: testDocumentRoot) }
        #expect(throws: FirebaseError.self) { try FirestoreValue(rest: json(#"{"fooValue": 1}"#), documentRoot: testDocumentRoot) }
        #expect(throws: FirebaseError.self) { try FirestoreValue(rest: json(#"{"integerValue": "x"}"#), documentRoot: testDocumentRoot) }
    }

    @Test("Paths split into collection and document")
    func paths() {
        #expect(FirestorePath.isDocument("users/alice"))
        #expect(!FirestorePath.isDocument("users"))
        #expect(!FirestorePath.isDocument("users/alice/orders"))
        #expect(FirestorePath.split(collectionPath: "users/alice/orders") == ("users/alice", "orders"))
        #expect(FirestorePath.split(collectionPath: "users") == ("", "users"))
        #expect(FirestorePath.absolute("/users/alice/", documentRoot: testDocumentRoot) == testDocumentRoot + "/users/alice")
        #expect(FirestorePath.absolute("", documentRoot: testDocumentRoot) == testDocumentRoot)
    }
}

@Suite("Firestore document JSON")
struct FirestoreDocumentJSONTests {
    @Test("Types JSON lacks are tagged and read back")
    func tags() throws {
        let fields: [String: FirestoreValue] = [
            "when": .timestamp("2026-10-12T08:00:00Z"),
            "owner": .reference("users/alice"),
            "where": .geoPoint(latitude: 45.4, longitude: 9.2),
            "raw": .bytes(Data("hi".utf8)),
            "whole": .double(3),
            "half": .double(0.5),
            "count": .integer(3),
            "tags": .array([.string("a")]),
            "nested": .map(["x": .null])
        ]
        let text = FirestoreDocumentJSON.text(fields: fields)
        #expect(text.contains(#""$timestamp": "2026-10-12T08:00:00Z""#))
        #expect(text.contains(#""$double": 3.0"#))
        #expect(text.contains(#""half": 0.5"#))
        #expect(try FirestoreDocumentJSON.fields(from: text) == fields)
    }

    @Test("A real map shaped like a tag survives inside $map")
    func mapEscape() throws {
        let value = FirestoreValue.map(["$ref": .string("not a reference")])
        let encoded = FirestoreDocumentJSON.json(value)
        #expect(encoded.text() == #"{"$map":{"$ref":"not a reference"}}"#)
        #expect(try FirestoreDocumentJSON.value(encoded) == value)
    }

    @Test("Invalid tags explain what they need")
    func invalidTags() {
        #expect(throws: FirebaseError.self) { try FirestoreDocumentJSON.value(json(#"{"$timestamp": "yesterday"}"#)) }
        #expect(throws: FirebaseError.self) { try FirestoreDocumentJSON.value(json(#"{"$ref": "users"}"#)) }
        #expect(throws: FirebaseError.self) { try FirestoreDocumentJSON.value(json(#"{"$geo": {"latitude": 99, "longitude": 0}}"#)) }
        #expect(throws: FirebaseError.self) { try FirestoreDocumentJSON.fields(from: "[1, 2]") }
    }
}
