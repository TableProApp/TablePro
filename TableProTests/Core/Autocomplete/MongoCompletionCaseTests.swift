//
//  MongoCompletionCaseTests.swift
//  TableProTests
//
//  MongoDB's vocabulary is JavaScript, so every name in it is case-significant.
//  Completion used to route it through a factory that uppercased, which offered
//  `$MATCH` and `DB` and produced pipelines the server rejects.
//

import Foundation
@testable import TablePro
import Testing

@MainActor
struct MongoCompletionCaseTests {
    private func service() -> MongoCompletionService {
        MongoCompletionService(schemaProvider: nil, databaseType: .mongodb)
    }

    private func completions(_ text: String) async -> [SQLCompletionItem] {
        let ns = text as NSString
        let session = await service().completions(in: ns, at: ns.length, isManualTrigger: true)
        return session?.items ?? []
    }

    @Test("A pipeline stage is offered and inserted in its own case")
    func pipelineStageKeepsItsCase() async {
        let items = await completions("db.orders.aggregate([{ $ma")
        let match = items.first { $0.label.lowercased() == "$match" }
        #expect(match?.label == "$match")
        #expect(match?.insertText == "$match")
        #expect(!items.contains { $0.insertText == "$MATCH" })
    }

    @Test("An uppercase prefix does not uppercase a stage")
    func uppercasePrefixDoesNotRecaseStage() async {
        let items = await completions("db.orders.aggregate([{ $MA")
        #expect(!items.contains { $0.insertText == "$MATCH" })
    }

    @Test("A camel-cased stage keeps its inner capitals")
    func camelCaseStageIsIntact() async {
        let items = await completions("db.orders.aggregate([{ $addf")
        #expect(items.contains { $0.insertText == "$addFields" })
    }

    @Test("The db handle is offered in lower case")
    func dbHandleKeepsItsCase() async {
        let items = await completions("d")
        #expect(items.contains { $0.insertText == "db" })
        #expect(!items.contains { $0.insertText == "DB" })
    }

    @Test("A collection method keeps its camel case")
    func collectionMethodKeepsItsCase() async {
        let items = await completions("db.orders.inserto")
        #expect(items.contains { $0.insertText == "insertOne()" })
    }

    @Test("A query operator keeps its case")
    func queryOperatorKeepsItsCase() async {
        let items = await completions("db.orders.find({ status: { $g")
        #expect(items.contains { $0.insertText == "$gte" })
        #expect(!items.contains { $0.insertText == "$GTE" })
    }

    @Test("Every item the Mongo service builds declares a fixed spelling")
    func everyMongoItemIsFixed() async {
        let items = await completions("")
        #expect(!items.isEmpty)
        #expect(items.allSatisfy { $0.caseFolding == .fixed })
    }
}
