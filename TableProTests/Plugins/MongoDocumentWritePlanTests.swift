//
//  MongoDocumentWritePlanTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

struct MongoDocumentWritePlanTests {
    /// Stands in for libbson, which the test target cannot link: every input here is already
    /// canonical, which is the one case where libbson hands the text back unchanged.
    private let canonical: (String) throws -> String = { $0 }

    @Test("An insert sends the document and shows it as insertOne")
    func insert() throws {
        let plan = try MongoDocumentWritePlan.make(
            collection: "events",
            operation: .insert(document: "{\n  \"name\": \"launch\"\n}"),
            canonicalize: canonical
        )
        #expect(plan?.write == .insert(document: #"{"name":"launch"}"#))
        #expect(plan?.statement == #"db.events.insertOne({"name":"launch"})"#)
    }

    @Test("An empty document is a valid insert")
    func emptyInsert() throws {
        let plan = try MongoDocumentWritePlan.make(
            collection: "events", operation: .insert(document: "{}"), canonicalize: canonical
        )
        #expect(plan?.write == .insert(document: "{}"))
    }

    @Test("Field order is kept, integer-like names included, which a JavaScript object would move")
    func fieldOrder() throws {
        let plan = try MongoDocumentWritePlan.make(
            collection: "events", operation: .insert(document: #"{"b":1,"2":2,"a":3}"#), canonicalize: canonical
        )
        #expect(plan?.write == .insert(document: #"{"b":1,"2":2,"a":3}"#))
    }

    @Test("Text libbson would misread is refused before it is asked")
    func strictBeforeLibbson() {
        var asked = false
        let spy: (String) throws -> String = { text in
            asked = true
            return text
        }
        #expect(throws: MongoDocumentText.Refusal.self) {
            try MongoDocumentWritePlan.make(
                collection: "events", operation: .insert(document: #"{"a":1} {"b":2}"#), canonicalize: spy
            )
        }
        #expect(!asked)
    }

    @Test("A wrapper libbson cannot read is refused with libbson's reason")
    func libbsonRefusal() {
        struct Unreadable: Error {}
        #expect(throws: Unreadable.self) {
            try MongoDocumentWritePlan.make(
                collection: "events",
                operation: .insert(document: #"{"_id":{"$oid":"nothex"}}"#),
                canonicalize: { _ in throw Unreadable() }
            )
        }
    }

    @Test("A collection name is quoted into the accessor, never spliced as code")
    func collectionNameIsQuoted() throws {
        let plan = try MongoDocumentWritePlan.make(
            collection: #"x").drop(); db.getCollection("y"#,
            operation: .insert(document: "{}"),
            canonicalize: canonical
        )
        #expect(plan?.statement == #"db.getCollection("x\").drop(); db.getCollection(\"y").insertOne({})"#)
    }

    private let stored = #"{"_id":{"$numberInt":"1"},"n":{"$numberInt":"5"}}"#

    @Test("An edit replaces the whole document under the guard, and says so with the collation it runs under")
    func replaceStatement() throws {
        let plan = try #require(try MongoDocumentWritePlan.make(
            collection: "events",
            operation: .replace(original: stored, edited: #"{"_id":{"$numberInt":"1"},"n":{"$numberInt":"6"}}"#),
            canonicalize: canonical
        ))
        let filter = try MongoDocumentGuard.filter(for: MongoDocumentText(parsing: stored))
        let replacement = #"{"_id":{"$numberInt":"1"},"n":{"$numberInt":"6"}}"#
        #expect(plan.write == .replace(filter: filter, replacement: replacement))
        #expect(plan.statement == #"db.events.replaceOne(\#(filter), \#(replacement), {"collation":{"locale":"simple"}})"#)
    }

    @Test("An edit that changes nothing writes nothing")
    func unchangedEdit() throws {
        let plan = try MongoDocumentWritePlan.make(
            collection: "events",
            operation: .replace(original: stored, edited: "{\n  \"n\": {\"$numberInt\": \"5\"}\n}"),
            canonicalize: { try MongoDocumentText(parsing: $0).compactText }
        )
        #expect(plan == nil)
    }

    @Test("The guard is built from the document as it was opened, not as it was edited")
    func guardFollowsTheOriginal() throws {
        let plan = try #require(try MongoDocumentWritePlan.make(
            collection: "events",
            operation: .replace(original: stored, edited: #"{"n":{"$numberLong":"5"}}"#),
            canonicalize: canonical
        ))
        guard case .replace(let filter, let replacement) = plan.write else {
            Issue.record("Expected a replace")
            return
        }
        #expect(filter.contains(#"{"$literal":\#(stored)}"#))
        #expect(replacement == #"{"_id":{"$numberInt":"1"},"n":{"$numberLong":"5"}}"#)
    }

    @Test("Both texts are read strictly before libbson sees either")
    func replaceReadsStrictly() {
        #expect(throws: MongoDocumentText.Refusal.self) {
            try MongoDocumentWritePlan.make(
                collection: "events",
                operation: .replace(original: stored, edited: #"{"n":1,"n":2}"#),
                canonicalize: canonical
            )
        }
    }
}
