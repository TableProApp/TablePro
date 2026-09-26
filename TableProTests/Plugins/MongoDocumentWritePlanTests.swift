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
        #expect(plan.document == #"{"name":"launch"}"#)
        #expect(plan.statement == #"db.events.insertOne({"name":"launch"})"#)
    }

    @Test("An empty document is a valid insert")
    func emptyInsert() throws {
        let plan = try MongoDocumentWritePlan.make(
            collection: "events", operation: .insert(document: "{}"), canonicalize: canonical
        )
        #expect(plan.document == "{}")
    }

    @Test("Field order is kept, integer-like names included, which a JavaScript object would move")
    func fieldOrder() throws {
        let plan = try MongoDocumentWritePlan.make(
            collection: "events", operation: .insert(document: #"{"b":1,"2":2,"a":3}"#), canonicalize: canonical
        )
        #expect(plan.document == #"{"b":1,"2":2,"a":3}"#)
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
        #expect(plan.statement == #"db.getCollection("x\").drop(); db.getCollection(\"y").insertOne({})"#)
    }
}
