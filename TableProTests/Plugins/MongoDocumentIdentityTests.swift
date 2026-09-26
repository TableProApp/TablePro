//
//  MongoDocumentIdentityTests.swift
//  TableProTests
//

import Foundation
import Testing

struct MongoDocumentIdentityTests {
    private let objectIdHex = "65f0a1b2c3d4e5f607182930"

    @Test("The locator is the compact canonical _id of libbson's spaced output")
    func readsLibbsonShapedText() {
        let cases: [(String, String)] = [
            (#"{ "$oid" : "65f0a1b2c3d4e5f607182930" }"#, #"{"$oid":"65f0a1b2c3d4e5f607182930"}"#),
            (#""plain""#, #""plain""#),
            (#"{ "$numberInt" : "1" }"#, #"{"$numberInt":"1"}"#),
            (#"{ "$numberLong" : "1" }"#, #"{"$numberLong":"1"}"#),
            (#"{ "$numberDouble" : "1.0" }"#, #"{"$numberDouble":"1.0"}"#),
            (#"{ "$date" : { "$numberLong" : "1714557600000" } }"#, #"{"$date":{"$numberLong":"1714557600000"}}"#),
            ("true", "true"),
            (#"{ "b" : { "$numberInt" : "2" }, "a" : { "$numberInt" : "1" } }"#, #"{"b":{"$numberInt":"2"},"a":{"$numberInt":"1"}}"#),
            (#"{ "$binary" : { "base64" : "AQID", "subType" : "00" } }"#, #"{"$binary":{"base64":"AQID","subType":"00"}}"#),
            (#"{ "$binary" : { "base64" : "OyQRAeK7QlWMr0E2xWapYg==", "subType" : "04" } }"#,
             #"{"$binary":{"base64":"OyQRAeK7QlWMr0E2xWapYg==","subType":"04"}}"#)
        ]
        for (stored, locator) in cases {
            let document = #"{ "_id" : \#(stored), "n" : { "$numberInt" : "1" } }"#
            #expect(MongoDocumentIdentity.locator(inDocument: document) == locator)
        }
    }

    @Test("An _id after other fields is found without being confused by braces inside strings")
    func idNotFirst() {
        let document = #"{ "a" : [ { "b" : "}]\"{" }, [ 1, 2 ] ], "c" : true, "_id" : "x" }"#
        #expect(MongoDocumentIdentity.locator(inDocument: document) == #""x""#)
    }

    @Test("A document with no _id has no locator")
    func noIdentity() {
        #expect(MongoDocumentIdentity.locator(inDocument: #"{ "a" : 1 }"#) == nil)
        #expect(MongoDocumentIdentity.locator(inDocument: "{}") == nil)
        #expect(MongoDocumentIdentity.locator(inDocument: "not json") == nil)
    }

    @Test("An ObjectId and a string with the same hex are different documents")
    func objectIdAndSameHexString() throws {
        let objectId = try #require(MongoDocumentIdentity.locator(
            inDocument: #"{ "_id" : { "$oid" : "\#(objectIdHex)" } }"#
        ))
        let string = try #require(MongoDocumentIdentity.locator(inDocument: #"{ "_id" : "\#(objectIdHex)" }"#))
        #expect(objectId != string)
        let identity = try MongoDocumentIdentity(locator: objectId)
        #expect(!identity.identifies(#"{ "_id" : "\#(objectIdHex)", "n" : 2 }"#))
        #expect(identity.identifies(#"{ "_id" : { "$oid" : "\#(objectIdHex)" }, "n" : 1 }"#))
    }

    @Test("A locator is read as one value, and anything more is refused")
    func strictLocator() {
        for text in [
            "1}); db.x.drop(); ({",
            #"1, "a": 2"#,
            #"1, "$where": "x""#,
            #"{"$ne": null}"#,
            #"{"$gt": ""}"#,
            "",
            #"1} {"_id": 2"#
        ] {
            #expect(throws: MongoDBDocumentEditingError.unknownDocument) {
                try MongoDocumentIdentity(locator: text)
            }
        }
    }

    @Test("A locator is kept compact, and its filter names only _id")
    func compactFilter() throws {
        let identity = try MongoDocumentIdentity(locator: #"{ "$oid" : "\#(objectIdHex)" }"#)
        #expect(identity.locator == #"{"$oid":"\#(objectIdHex)"}"#)
        #expect(identity.filter == #"{"_id":{"$oid":"\#(objectIdHex)"}}"#)
    }

    @Test("A query's numeric and field-order leniency does not identify a document")
    func noNumericLeniency() throws {
        let int32 = try MongoDocumentIdentity(locator: #"{"$numberInt":"1"}"#)
        #expect(!int32.identifies(#"{ "_id" : { "$numberDouble" : "1.0" } }"#))
        #expect(!int32.identifies(#"{ "_id" : { "$numberLong" : "1" } }"#))
        let document = try MongoDocumentIdentity(locator: #"{"a":{"$numberInt":"1"}}"#)
        #expect(!document.identifies(#"{ "_id" : { "a" : { "$numberLong" : "1" } } }"#))
        let ordered = try MongoDocumentIdentity(locator: #"{"a":{"$numberInt":"1"},"b":{"$numberInt":"2"}}"#)
        #expect(!ordered.identifies(#"{ "_id" : { "b" : { "$numberInt" : "2" }, "a" : { "$numberInt" : "1" } } }"#))
    }

    @Test("Two Unicode spellings of one string are two identities, as they are to the server")
    func unicodeSpellings() throws {
        let composed = try MongoDocumentIdentity(locator: "\"caf\u{E9}\"")
        #expect(composed.identifies("{ \"_id\" : \"caf\u{E9}\" }"))
        #expect(!composed.identifies("{ \"_id\" : \"cafe\u{301}\" }"))
    }
}
