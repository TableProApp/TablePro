//
//  MongoContextAnalyzerTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("MongoDB Context Analyzer")
struct MongoContextAnalyzerTests {
    private func analyze(_ text: String) -> MongoContext {
        let ns = text as NSString
        return MongoContextAnalyzer.analyze(text: ns, cursor: ns.length)
    }

    // MARK: - Dot positions

    @Test("db. offers database members")
    func testDatabaseMember() {
        #expect(analyze("db.").position == .databaseMember)
    }

    @Test("db.users. offers collection methods")
    func testCollectionMethod() {
        #expect(analyze("db.users.").position == .collectionMethod(collection: "users"))
    }

    @Test("a dotted collection name is kept whole")
    func testDottedCollectionMethod() {
        #expect(analyze("db.my.coll.").position == .collectionMethod(collection: "my.coll"))
    }

    @Test("a partial method name after the dot becomes the prefix")
    func testCollectionMethodPrefix() {
        let context = analyze("db.users.fin")
        #expect(context.position == .collectionMethod(collection: "users"))
        #expect(context.prefix == "fin")
    }

    // MARK: - Documents

    @Test("the first find argument is a filter document")
    func testFilterDocument() {
        #expect(analyze("db.users.find({").position == .filterDocument(collection: "users"))
    }

    @Test("the second find argument is a projection document")
    func testProjectionDocument() {
        #expect(analyze("db.users.find({}, {").position == .projectionDocument(collection: "users"))
    }

    @Test("the second updateOne argument is an update document")
    func testUpdateDocument() {
        #expect(analyze("db.users.updateOne({}, {").position == .updateDocument)
    }

    @Test("the first updateOne argument is still a filter")
    func testUpdateFilterDocument() {
        #expect(analyze("db.users.updateOne({").position == .filterDocument(collection: "users"))
    }

    @Test("an array-form update is an aggregation pipeline stage list")
    func testUpdatePipelineStage() {
        #expect(analyze("db.users.updateOne({}, [{").position == .updatePipelineStage)
    }

    @Test("insertOne takes a plain document, not operators")
    func testPlainDocument() {
        #expect(analyze("db.users.insertOne({").position == .plainDocument(collection: "users"))
    }

    // MARK: - Pipelines

    @Test("the top level of an aggregate array is a stage position")
    func testPipelineStage() {
        #expect(analyze("db.orders.aggregate([{").position == .pipelineStage(collection: "orders"))
    }

    @Test("a second stage is still a stage position")
    func testSecondPipelineStage() {
        #expect(analyze("db.orders.aggregate([{$match: {}}, {").position == .pipelineStage(collection: "orders"))
    }

    @Test("inside a stage body is an expression position")
    func testStageExpression() {
        #expect(analyze("db.orders.aggregate([{$group: {").position == .stageExpression(collection: "orders"))
    }

    @Test("aggregate without its array is not a stage position")
    func testAggregateWithoutArray() {
        #expect(analyze("db.orders.aggregate({").position == .suppressed)
    }

    // MARK: - Prefixes

    @Test("a dollar operator prefix keeps its sigil")
    func testDollarPrefix() {
        let context = analyze("db.users.find({$g")
        #expect(context.position == .filterDocument(collection: "users"))
        #expect(context.prefix == "$g")
    }

    @Test("a system variable prefix keeps both sigils")
    func testDoubleDollarPrefix() {
        #expect(analyze("db.o.aggregate([{$project: {a: \"$$N").prefix == "$$N")
    }

    @Test("a field prefix has no sigil")
    func testFieldPrefix() {
        #expect(analyze("db.users.find({na").prefix == "na")
    }

    // MARK: - Suppression

    @Test("a line comment suppresses completion")
    func testLineCommentSuppressed() {
        #expect(analyze("db.users.find({}) // db.").position == .suppressed)
    }

    @Test("a block comment suppresses completion")
    func testBlockCommentSuppressed() {
        #expect(analyze("/* db.users.find({").position == .suppressed)
    }

    @Test("braces inside a string literal do not open a document")
    func testBraceInStringIgnored() {
        #expect(analyze("db.users.find({name: \"{\"}, {").position == .projectionDocument(collection: "users"))
    }

    @Test("an escaped quote does not end the string")
    func testEscapedQuoteInString() {
        #expect(analyze("db.users.find({name: \"a\\\"b\"}, {").position == .projectionDocument(collection: "users"))
    }

    @Test("an empty document is a statement start")
    func testEmptyIsStatementStart() {
        #expect(analyze("").position == .statementStart)
    }

    @Test("a bare word at the top level is a statement start")
    func testBareWordStatementStart() {
        let context = analyze("us")
        #expect(context.position == .statementStart)
        #expect(context.prefix == "us")
    }
}
