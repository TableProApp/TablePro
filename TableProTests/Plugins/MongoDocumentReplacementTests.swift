//
//  MongoDocumentReplacementTests.swift
//  TableProTests
//

import Foundation
import Testing

struct MongoDocumentReplacementTests {
    private func replacement(original: String, edited: String) throws -> MongoDocumentReplacement {
        try MongoDocumentReplacement(
            original: MongoDocumentText(parsing: original),
            edited: MongoDocumentText(parsing: edited)
        )
    }

    private let original = #"{"_id":{"$numberInt":"1"},"a":{"$numberInt":"1"},"b":"x"}"#

    @Test("The stored _id goes first, then the fields in the order they were written")
    func idFirstThenWrittenOrder() throws {
        let result = try replacement(
            original: original,
            edited: #"{"z":{"$numberInt":"1"},"_id":{"$numberInt":"1"},"a":{"$numberInt":"2"}}"#
        )
        #expect(result.document.compactText == #"{"_id":{"$numberInt":"1"},"z":{"$numberInt":"1"},"a":{"$numberInt":"2"}}"#)
        #expect(result.changesDocument)
    }

    @Test("An _id the text leaves out is put back rather than dropped")
    func omittedIdIsRestored() throws {
        let result = try replacement(original: original, edited: #"{"a":{"$numberInt":"1"},"b":"x"}"#)
        #expect(result.document.compactText == original)
        #expect(!result.changesDocument)
    }

    @Test("A changed _id is refused, a reordered subdocument _id included")
    func changedIdIsRefused() {
        #expect(throws: MongoDBDocumentEditingError.identityChanged) {
            try replacement(original: original, edited: #"{"_id":{"$numberInt":"2"}}"#)
        }
        #expect(throws: MongoDBDocumentEditingError.identityChanged) {
            try replacement(original: original, edited: #"{"_id":{"$numberLong":"1"}}"#)
        }
        #expect(throws: MongoDBDocumentEditingError.identityChanged) {
            try replacement(
                original: #"{"_id":{"a":{"$numberInt":"1"},"b":{"$numberInt":"2"}}}"#,
                edited: #"{"_id":{"b":{"$numberInt":"2"},"a":{"$numberInt":"1"}}}"#
            )
        }
    }

    @Test("An unchanged document changes nothing")
    func unchanged() throws {
        #expect(try !replacement(original: original, edited: original).changesDocument)
    }

    @Test("Dotted, empty, integer-like and nested $ names are kept verbatim and in order")
    func oddNames() throws {
        let edited = #"{"_id":{"$numberInt":"1"},"2":"two","price.usd":{"$numberInt":"9"},"":"e","x":{"$w":{"$numberInt":"1"}}}"#
        #expect(try replacement(original: original, edited: edited).document.compactText == edited)
    }

    @Test("A top-level $ field is refused when the text is read")
    func topLevelOperator() {
        #expect(throws: MongoDocumentText.Refusal.operatorField("$p")) {
            try replacement(original: original, edited: #"{"$p":{"$numberInt":"1"}}"#)
        }
    }

    @Test("A value respelled in another Unicode form is a change")
    func unicodeRespelling() throws {
        let composed = "{\"_id\":{\"$numberInt\":\"1\"},\"s\":\"caf\u{E9}\"}"
        let decomposed = "{\"_id\":{\"$numberInt\":\"1\"},\"s\":\"cafe\u{301}\"}"
        #expect(try replacement(original: composed, edited: decomposed).changesDocument)
    }

    @Test("Timestamp(0, 0) in a top-level field is refused, and nested it is kept")
    func emptyTimestamp() throws {
        #expect(throws: MongoDBDocumentEditingError.emptyTimestamp("ts")) {
            try replacement(original: original, edited: #"{"ts":{"$timestamp":{"t":0,"i":0}}}"#)
        }
        let nested = #"{"_id":{"$numberInt":"1"},"o":{"ts":{"$timestamp":{"t":0,"i":0}}}}"#
        #expect(try replacement(original: original, edited: nested).document.compactText == nested)
        let stamped = #"{"_id":{"$numberInt":"1"},"ts":{"$timestamp":{"t":5,"i":1}}}"#
        #expect(try replacement(original: original, edited: stamped).changesDocument)
    }

    @Test("A document with no _id cannot be replaced")
    func missingIdentity() {
        #expect(throws: MongoDBDocumentEditingError.missingIdentity) {
            try replacement(original: #"{"a":{"$numberInt":"1"}}"#, edited: #"{"a":{"$numberInt":"2"}}"#)
        }
    }
}
