//
//  MongoEditableDocumentTests.swift
//  TableProTests
//

import Foundation
import Testing

private struct FakeLibbson: MongoDocumentCodec {
    var readsBackExactly = true
    var filterSize: Int? = 100
    var documentSize = 100

    func isSameDocument(_ text: String, asCanonical canonical: String) -> Bool {
        readsBackExactly
    }

    func bsonSize(of json: String) -> Int? {
        json.contains(#""$expr""#) ? filterSize : documentSize
    }
}

/// The steps of one read in the order they ran, with a cancel that lands during one of them.
private final class ReadSteps {
    var serverVersion: String? = "7.0.43"
    var listCollectionsReply: () throws -> [String: Any]? = { nil }
    var cancelDuring: String?
    private(set) var ran: [String] = []
    private var isCancelled = false

    func read() throws -> [MongoStoredDocument] {
        try MongoEditableDocument.readStored(
            serverVersion: {
                run("version")
                return serverVersion
            },
            listCollectionsReply: {
                run("listCollections")
                return try listCollectionsReply()
            },
            storedDocuments: {
                run("find")
                return []
            },
            checkCancelled: {
                if isCancelled { throw CancellationError() }
            }
        )
    }

    private func run(_ step: String) {
        ran.append(step)
        if step == cancelDuring { isCancelled = true }
    }
}

struct MongoEditableDocumentTests {
    private let identity: MongoDocumentIdentity
    private let stored = #"{ "_id" : { "$numberInt" : "1" }, "n" : { "$numberLong" : "5" }, "d" : { "$numberDouble" : "1.0" } }"#

    init() throws {
        identity = try MongoDocumentIdentity(locator: #"{"$numberInt":"1"}"#)
    }

    private func open(
        _ documents: [MongoStoredDocument],
        codec: MongoDocumentCodec = FakeLibbson()
    ) throws -> String? {
        try MongoEditableDocument.text(for: identity, among: documents, codec: codec)
    }

    @Test("A document that no longer exists opens as nil, even when the query matched another one")
    func gone() throws {
        #expect(try open([]) == nil)
        let lenientMatch = MongoStoredDocument(canonical: #"{ "_id" : { "$numberDouble" : "1.0" } }"#, isRepresentable: true)
        #expect(try open([lenientMatch]) == nil)
    }

    @Test("Two documents with the locator are refused rather than guessed between")
    func ambiguous() {
        let document = MongoStoredDocument(canonical: stored, isRepresentable: true)
        #expect(throws: MongoDBDocumentEditingError.ambiguousIdentity) {
            try open([document, document])
        }
    }

    @Test("The readable form is shown when libbson reads it back as the same document")
    func readable() throws {
        let text = try open([MongoStoredDocument(canonical: stored, isRepresentable: true)])
        #expect(text == """
            {
              "_id": 1,
              "n": {"$numberLong":"5"},
              "d": 1.0
            }
            """)
    }

    @Test("The canonical form is shown when the readable one would not read back the same")
    func canonicalFallback() throws {
        let text = try open(
            [MongoStoredDocument(canonical: stored, isRepresentable: true)],
            codec: FakeLibbson(readsBackExactly: false)
        )
        #expect(text?.contains(#""_id": {"$numberInt":"1"}"#) == true)
        #expect(text?.contains(#""d": {"$numberDouble":"1.0"}"#) == true)
    }

    @Test("A document libbson cannot write back exactly is refused when it opens")
    func inexact() {
        #expect(throws: MongoDBDocumentEditingError.inexactAsText) {
            try open([MongoStoredDocument(canonical: stored, isRepresentable: false)])
        }
    }

    @Test("A stored top-level $ field and a repeated field are refused when the document opens")
    func unreadableAsText() {
        #expect(throws: MongoDocumentText.Refusal.operatorField("$p")) {
            try open([MongoStoredDocument(canonical: #"{ "_id" : { "$numberInt" : "1" }, "$p" : 1 }"#, isRepresentable: true)])
        }
        #expect(throws: MongoDocumentText.Refusal.duplicateField("a")) {
            try open([MongoStoredDocument(
                canonical: #"{ "_id" : { "$numberInt" : "1" }, "a" : 1, "a" : 2 }"#,
                isRepresentable: true
            )])
        }
    }

    @Test("Timestamp(0, 0) in a top-level field is refused when the document opens")
    func emptyTimestamp() {
        let document = #"{ "_id" : { "$numberInt" : "1" }, "ts" : { "$timestamp" : { "t" : 0, "i" : 0 } } }"#
        #expect(throws: MongoDBDocumentEditingError.emptyTimestamp("ts")) {
            try open([MongoStoredDocument(canonical: document, isRepresentable: true)])
        }
    }

    @Test("A guard libbson cannot read is refused as too deep")
    func unreadableGuard() {
        #expect(throws: MongoDocumentGuard.Refusal.tooDeep) {
            try open([MongoStoredDocument(canonical: stored, isRepresentable: true)], codec: FakeLibbson(filterSize: nil))
        }
    }

    @Test("A document whose guarded replace would pass 16 MB is refused when it opens")
    func tooLarge() throws {
        let limit = MongoEditableDocument.commandSizeLimit
        let document = MongoStoredDocument(canonical: stored, isRepresentable: true)
        #expect(throws: MongoDBDocumentEditingError.tooLarge) {
            try open([document], codec: FakeLibbson(filterSize: limit / 2 + 1, documentSize: limit / 2))
        }
        #expect(try open([document], codec: FakeLibbson(filterSize: limit / 2, documentSize: limit / 2)) != nil)
    }

    @Test("Only a plain collection is edited: a view, a time-series collection and an unknown kind are refused")
    func namespaceKinds() {
        func refusal(_ type: String?) -> MongoDBDocumentEditingError? {
            var entry: [String: Any] = ["name": "c"]
            entry["type"] = type
            return MongoEditableDocument.namespaceRefusal(listCollectionsReply: ["cursor": ["firstBatch": [entry]]])
        }
        #expect(refusal("collection") == nil)
        #expect(refusal("view") == .view)
        #expect(refusal("timeseries") == .timeSeries)
        #expect(refusal("ledger") == .notACollection("ledger"))
        #expect(refusal(nil) == nil)
        #expect(MongoEditableDocument.namespaceRefusal(listCollectionsReply: [:]) == nil)
        #expect(MongoEditableDocument.namespaceTypeCommand(for: #"a"b"#) == #"{"listCollections":1,"filter":{"name":"a\"b"}}"#)
    }

    @Test("A NaN libbson cannot write back is refused for being a NaN")
    func notANumberBeforeInexact() {
        let document = #"{ "_id" : { "$numberInt" : "1" }, "n" : { "$numberDouble" : "NaN" } }"#
        #expect(throws: MongoDocumentGuard.Refusal.notANumber) {
            try open([MongoStoredDocument(canonical: document, isRepresentable: false)])
        }
        #expect(throws: MongoDocumentGuard.Refusal.notANumber) {
            try open([MongoStoredDocument(canonical: document, isRepresentable: true)])
        }
    }

    @Test("The read asks for no limit, so documents the collation also finds cannot use it up")
    func readOptions() {
        #expect(MongoEditableDocument.readOptions(maxTimeMS: nil) == "{}")
        #expect(MongoEditableDocument.readOptions(maxTimeMS: 30_000) == #"{"maxTimeMS":30000}"#)
    }

    @Test("A read goes on past documents the collation found and keeps only exact matches")
    func lenientMatchesAreReadPast() {
        var matches = MongoExactMatches(identity: identity)
        let lenient = [
            #"{ "_id" : { "$numberDouble" : "1.0" } }"#,
            #"{ "_id" : { "$numberLong" : "1" } }"#,
            #"{ "_id" : { "$numberDecimal" : "1.00" } }"#
        ]
        var asked = 0
        for canonical in lenient {
            matches.consider(canonical) {
                asked += 1
                return true
            }
        }
        #expect(matches.documents.isEmpty)
        #expect(!matches.isDecided)
        #expect(asked == 0, "Only an exact match is read back through libbson")

        matches.consider(stored) { true }
        #expect(matches.documents == [MongoStoredDocument(canonical: stored, isRepresentable: true)])
        #expect(!matches.isDecided)
    }

    @Test("A second exact match decides the read, and what it gathered is refused as ambiguous")
    func secondExactMatchDecides() {
        var matches = MongoExactMatches(identity: identity)
        matches.consider(#"{ "_id" : "1" }"#) { true }
        matches.consider(stored) { true }
        matches.consider(#"{ "_id" : { "$numberLong" : "1" } }"#) { true }
        #expect(!matches.isDecided)
        matches.consider(stored) { false }
        #expect(matches.isDecided)
        matches.consider(stored) { true }
        #expect(matches.documents.count == 2)
        #expect(throws: MongoDBDocumentEditingError.ambiguousIdentity) {
            try open(matches.documents)
        }
    }

    @Test("A cancel that lands during one step of the read stops the next one")
    func cancelStopsTheNextStep() throws {
        let duringVersion = ReadSteps()
        duringVersion.cancelDuring = "version"
        #expect(throws: CancellationError.self) { try duringVersion.read() }
        #expect(duringVersion.ran == ["version"])

        let duringListing = ReadSteps()
        duringListing.cancelDuring = "listCollections"
        #expect(throws: CancellationError.self) { try duringListing.read() }
        #expect(duringListing.ran == ["version", "listCollections"])

        let uncancelled = ReadSteps()
        _ = try uncancelled.read()
        #expect(uncancelled.ran == ["version", "listCollections", "find"])
    }

    @Test("A collection the user cannot list is still read, but a cancel while listing it stops the read")
    func listingFailure() throws {
        let unauthorized = ReadSteps()
        unauthorized.listCollectionsReply = { throw NSError(domain: "MongoDB", code: 13) }
        _ = try unauthorized.read()
        #expect(unauthorized.ran == ["version", "listCollections", "find"])

        let cancelled = ReadSteps()
        cancelled.listCollectionsReply = { throw CancellationError() }
        #expect(throws: CancellationError.self) { try cancelled.read() }
        #expect(cancelled.ran == ["version", "listCollections"])
    }

    @Test("An old server and a view are refused before the documents are read")
    func refusedBeforeTheRead() {
        let old = ReadSteps()
        old.serverVersion = "3.6.23"
        #expect(throws: MongoDBDocumentEditingError.serverTooOld) { try old.read() }
        #expect(old.ran == ["version"])

        let view = ReadSteps()
        view.listCollectionsReply = { ["cursor": ["firstBatch": [["name": "v", "type": "view"]]]] }
        #expect(throws: MongoDBDocumentEditingError.view) { try view.read() }
        #expect(view.ran == ["version", "listCollections"])
    }

    @Test("Editing needs MongoDB 4.0, and a server whose version is unknown is let through")
    func serverFloor() {
        #expect(!MongoDBCapabilities.parse("3.6.23").supportsDocumentReplaceGuard)
        #expect(MongoDBCapabilities.parse("4.0.0").supportsDocumentReplaceGuard)
        #expect(MongoDBCapabilities.parse("7.0.43").supportsDocumentReplaceGuard)
        #expect(MongoDBCapabilities.parse(nil).supportsDocumentReplaceGuard)
    }
}
