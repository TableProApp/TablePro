//
//  MongoShellParserChainedMethodTests.swift
//  TableProTests
//
//  Cursor methods chained onto a query: .sort(), .limit(), .skip().
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("MongoDB Shell Parser Chained Methods")
struct MongoShellParserChainedMethodTests {
    @Test("aggregate keeps a chained limit as a pipeline stage")
    func testAggregateChainedLimitBecomesStage() throws {
        let op = try MongoShellParser.parse("db.orders.aggregate([{\"$match\": {}}]).limit(10)")
        guard case .aggregate(let collection, let pipeline) = op else {
            Issue.record("Expected .aggregate operation")
            return
        }
        #expect(collection == "orders")
        #expect(pipeline == "[{\"$match\": {}},{\"$limit\":10}]")
    }

    @Test("aggregate keeps chained sort, skip and limit in cursor order")
    func testAggregateChainedSortSkipLimit() throws {
        let op = try MongoShellParser.parse("db.orders.aggregate([]).sort({a: 1}).skip(5).limit(10)")
        guard case .aggregate(_, let pipeline) = op else {
            Issue.record("Expected .aggregate operation")
            return
        }
        #expect(pipeline == "[{\"$sort\":{a: 1}},{\"$skip\":5},{\"$limit\":10}]")
    }

    @Test("aggregate without chained methods keeps its pipeline untouched")
    func testAggregateWithoutChainUnchanged() throws {
        let op = try MongoShellParser.parse("db.orders.aggregate([{\"$match\": {}}])")
        guard case .aggregate(_, let pipeline) = op else {
            Issue.record("Expected .aggregate operation")
            return
        }
        #expect(pipeline == "[{\"$match\": {}}]")
    }

    @Test("find still applies chained cursor options")
    func testFindChainedOptionsStillApply() throws {
        let op = try MongoShellParser.parse("db.users.find({}).sort({a: -1}).skip(2).limit(7)")
        guard case .find(_, _, let options) = op else {
            Issue.record("Expected .find operation")
            return
        }
        #expect(options.sort == "{a: -1}")
        #expect(options.skip == 2)
        #expect(options.limit == 7)
    }

    @Test("an unknown chained method is rejected instead of dropped")
    func testUnknownChainedMethodThrows() {
        #expect(throws: MongoShellParseError.self) {
            try MongoShellParser.parse("db.users.find({}).collation({locale: \"en\"})")
        }
    }

    @Test("chaining onto an operation that returns no cursor is rejected")
    func testChainOnNonCursorOperationThrows() {
        #expect(throws: MongoShellParseError.self) {
            try MongoShellParser.parse("db.users.insertOne({a: 1}).limit(5)")
        }
    }

    @Test("a non-numeric limit is rejected")
    func testNonNumericLimitThrows() {
        #expect(throws: MongoShellParseError.self) {
            try MongoShellParser.parse("db.users.find({}).limit(abc)")
        }
    }
}
