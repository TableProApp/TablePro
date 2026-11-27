import Foundation
@testable import TableProMobile
import TableProPluginKit
import Testing

struct MongoDBReadMemoryTests {
    private static func cursor() -> MongoScriptCursor {
        MongoScriptCursor(handle: 1, kind: .find(filter: "{}"), database: "db", collection: "c")
    }

    private static let documents = MongoScriptDocumentBatch(
        json: (0..<5).map { #"{"_id":{"$numberInt":"\#($0)"}}"# }, isTruncated: true
    )

    @Test("A cursor paged to its end answers done and empty, loads once, and keeps the read's truncation")
    func drainedCursorPagesAsDone() throws {
        let cursor = Self.cursor()
        var loads = 0
        let loader: (MongoScriptCursor) throws -> MongoScriptDocumentBatch = { _ in
            loads += 1
            return Self.documents
        }
        let first = try cursor.page(size: 3, loader: loader)
        #expect(first.batch.json == Array(Self.documents.json[0..<3]))
        #expect(!first.done)
        let second = try cursor.page(size: 3, loader: loader)
        #expect(second.batch.json == Array(Self.documents.json[3...]))
        #expect(second.done)
        let after = try cursor.page(size: 3, loader: loader)
        #expect(after.batch.json.isEmpty)
        #expect(after.done)
        #expect(after.batch.isTruncated)
        #expect(try cursor.remaining(loader: loader).json.isEmpty)
        #expect(loads == 1)
    }

    @Test("A cursor drained by remaining answers empty from then on, and keeps the read's truncation")
    func remainingDrainsTheCursor() throws {
        let cursor = Self.cursor()
        var loads = 0
        let loader: (MongoScriptCursor) throws -> MongoScriptDocumentBatch = { _ in
            loads += 1
            return Self.documents
        }
        _ = try cursor.page(size: 2, loader: loader)
        #expect(try cursor.remaining(loader: loader).json == Array(Self.documents.json[2...]))
        let again = try cursor.remaining(loader: loader)
        #expect(again.json.isEmpty)
        #expect(again.isTruncated)
        let page = try cursor.page(size: 10, loader: loader)
        #expect(page.done)
        #expect(page.batch.json.isEmpty)
        #expect(loads == 1)
    }

    private static func read(_ texts: [String]) -> MongoReadDocuments {
        MongoScriptDocumentBatch(json: texts, isTruncated: false).readDocuments
    }

    @Test("Number kinds of documents of one shape, two shapes and a changed shape answer per document")
    func numberKindsPerDocument() {
        let read = Self.read([
            #"{"_id":{"$numberInt":"1"},"a":{"$numberInt":"1"},"b":{"$numberLong":"2"}}"#,
            #"{"_id":{"$numberInt":"2"},"a":{"$numberInt":"5"},"b":{"$numberLong":"6"}}"#,
            #"{"_id":{"$numberInt":"3"},"a":{"$numberDouble":"1.5"},"s":"text"}"#,
            #"{"_id":{"$numberInt":"4"},"s":"text"}"#,
        ])
        let kinds = MongoDBNumberKinds.recording(read, representation: .unspecified)
        #expect(kinds.kinds(ofRow: #"{"$numberInt":"1"}"#) == ["a": .int32, "b": .int64])
        #expect(kinds.kinds(ofRow: #"{"$numberInt":"2"}"#) == ["a": .int32, "b": .int64])
        #expect(kinds.kinds(ofRow: #"{"$numberInt":"3"}"#) == ["a": .double])
        #expect(kinds.kinds(ofRow: #"{"$numberInt":"4"}"#)?.isEmpty == true)
        #expect(kinds.count == 5)

        let changed = Self.read([#"{"_id":{"$numberInt":"2"},"a":{"$numberDecimal":"5"}}"#])
        let merged = kinds.merging(MongoDBNumberKinds.recording(changed, representation: .unspecified))
        #expect(merged.kinds(ofRow: #"{"$numberInt":"1"}"#) == ["a": .int32, "b": .int64])
        #expect(merged.kinds(ofRow: #"{"$numberInt":"2"}"#) == ["a": .decimal128])
        #expect(merged.count == 4)
    }

    @Test("Locators the read already took give the same kinds as reading them from each document")
    func givenLocatorsMatchParsedOnes() {
        let texts = [
            #"{"_id":{"$oid":"64b7f0000000000000000001"},"n":{"$numberLong":"7"}}"#,
            #"{"_id":"text id","n":{"$numberInt":"7"}}"#,
        ]
        var read = Self.read(texts)
        let parsed = MongoDBNumberKinds.recording(read, representation: .unspecified)
        read.locators = texts.map(MongoDocumentIdentity.locator(inDocument:))
        let given = MongoDBNumberKinds.recording(read, representation: .unspecified)
        for locator in read.locators?.compactMap({ $0 }) ?? [] {
            #expect(given.kinds(ofRow: locator) == parsed.kinds(ofRow: locator))
        }
        #expect(given.count == parsed.count)
    }
}
