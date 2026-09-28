//
//  MongoDocumentPresentationTests.swift
//  TableProTests
//

import Foundation
import Testing

struct MongoDocumentPresentationTests {
    private func shown(_ canonicalValue: String) throws -> String {
        let document = try MongoDocumentText(parsing: #"{"v":\#(canonicalValue)}"#)
        let value = try #require(document.value(of: "v"))
        return MongoDocumentPresentation.readable(value).compactText
    }

    @Test("A 32-bit integer reads as a bare number")
    func int32() throws {
        #expect(try shown(#"{"$numberInt":"42"}"#) == "42")
    }

    @Test("A 64-bit integer inside the 32-bit range keeps its wrapper, since bare it would read back as 32-bit")
    func smallInt64() throws {
        #expect(try shown(#"{"$numberLong":"5"}"#) == #"{"$numberLong":"5"}"#)
        #expect(try shown(#"{"$numberLong":"2147483647"}"#) == #"{"$numberLong":"2147483647"}"#)
    }

    @Test("A 64-bit integer outside the 32-bit range reads as a bare number")
    func largeInt64() throws {
        #expect(try shown(#"{"$numberLong":"9007199254740993"}"#) == "9007199254740993")
        #expect(try shown(#"{"$numberLong":"-2147483649"}"#) == "-2147483649")
    }

    @Test("A double reads in its shortest exact form and always shows it is a double")
    func doubles() throws {
        #expect(try shown(#"{"$numberDouble":"0.10000000000000000555"}"#) == "0.1")
        #expect(try shown(#"{"$numberDouble":"3.0"}"#) == "3.0")
        #expect(try shown(#"{"$numberDouble":"-0.0"}"#) == "-0.0")
        #expect(try shown(#"{"$numberDouble":"1e+300"}"#) == "1e+300")
    }

    @Test("A double JSON cannot spell keeps its wrapper")
    func specialDoubles() throws {
        #expect(try shown(#"{"$numberDouble":"Infinity"}"#) == #"{"$numberDouble":"Infinity"}"#)
        #expect(try shown(#"{"$numberDouble":"NaN"}"#) == #"{"$numberDouble":"NaN"}"#)
    }

    @Test("A date from 1970 through 9999 reads as ISO text, keeping its milliseconds")
    func relaxedDates() throws {
        #expect(try shown(#"{"$date":{"$numberLong":"1714557600123"}}"#) == #"{"$date":"2024-05-01T10:00:00.123Z"}"#)
        #expect(try shown(#"{"$date":{"$numberLong":"0"}}"#) == #"{"$date":"1970-01-01T00:00:00Z"}"#)
        #expect(try shown(#"{"$date":{"$numberLong":"253402300799999"}}"#) == #"{"$date":"9999-12-31T23:59:59.999Z"}"#)
    }

    @Test("A date outside the range libbson reads back as ISO keeps its canonical form")
    func canonicalDates() throws {
        #expect(try shown(#"{"$date":{"$numberLong":"-1000"}}"#) == #"{"$date":{"$numberLong":"-1000"}}"#)
        #expect(try shown(#"{"$date":{"$numberLong":"253402300800000"}}"#) == #"{"$date":{"$numberLong":"253402300800000"}}"#)
    }

    @Test("Other wrappers are left exactly as they are")
    func otherWrappers() throws {
        for wrapper in [
            #"{"$oid":"507f1f77bcf86cd799439011"}"#,
            #"{"$numberDecimal":"1.10"}"#,
            #"{"$binary":{"base64":"AAAA","subType":"04"}}"#,
            #"{"$timestamp":{"t":5,"i":1}}"#
        ] {
            #expect(try shown(wrapper) == wrapper)
        }
    }

    @Test("Numbers inside arrays and subdocuments are made readable too")
    func nested() throws {
        #expect(try shown(#"[{"$numberInt":"1"},{"a":{"$numberInt":"2"}}]"#) == #"[1,{"a":2}]"#)
    }

    @Test("The editable text is indented, keeps field order and puts a wrapper on one line")
    func editableText() throws {
        let document = try MongoDocumentText(
            parsing: #"{"_id":{"$oid":"507f1f77bcf86cd799439011"},"n":{"$numberInt":"1"},"tags":[],"o":{"k":"v"}}"#
        )
        #expect(MongoDocumentPresentation.editableText(document) == """
            {
              "_id": {"$oid":"507f1f77bcf86cd799439011"},
              "n": 1,
              "tags": [],
              "o": {
                "k": "v"
              }
            }
            """)
    }

    @Test("The canonical fallback keeps every wrapper and the same layout")
    func prettyCanonical() throws {
        let document = try MongoDocumentText(
            parsing: #"{"_id":{"$numberInt":"1"},"n":{"$numberLong":"5"},"o":{"k":{"$numberDouble":"0.1"}}}"#
        )
        #expect(MongoDocumentPresentation.prettyCanonical(document) == """
            {
              "_id": {"$numberInt":"1"},
              "n": {"$numberLong":"5"},
              "o": {
                "k": {"$numberDouble":"0.1"}
              }
            }
            """)
    }

    @Test("The editable text reads back as the same document")
    func editableTextRereads() throws {
        let document = try MongoDocumentText(parsing: #"{"a":[1,{"b":[]}],"s":"x\ny"}"#)
        let reread = try MongoDocumentText(parsing: MongoDocumentPresentation.editableText(document))
        #expect(reread == document)
    }
}
