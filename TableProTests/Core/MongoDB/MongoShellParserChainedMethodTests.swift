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

    // MARK: - Write Options

    @Test("updateOne without options keeps the original operation case")
    func testUpdateOneWithoutOptionsUnchanged() throws {
        let op = try MongoShellParser.parse("db.users.updateOne({a: 1}, {$set: {b: 2}})")
        guard case .updateOne(let collection, let filter, let update) = op else {
            Issue.record("Expected .updateOne operation")
            return
        }
        #expect(collection == "users")
        #expect(filter == "{a: 1}")
        #expect(update == "{$set: {b: 2}}")
    }

    @Test("upsert in the third argument is carried, not dropped")
    func testUpsertCarried() throws {
        let op = try MongoShellParser.parse("db.users.updateOne({a: 1}, {$set: {b: 2}}, {upsert: true})")
        guard case .write(let kind, let collection, _, _, let options) = op else {
            Issue.record("Expected .write operation")
            return
        }
        #expect(kind == .updateOne)
        #expect(collection == "users")
        #expect(options.upsert)
    }

    @Test("upsert false is carried as false")
    func testUpsertFalse() throws {
        let op = try MongoShellParser.parse("db.users.updateMany({}, {$set: {b: 2}}, {upsert: false})")
        guard case .write(let kind, _, _, _, let options) = op else {
            Issue.record("Expected .write operation")
            return
        }
        #expect(kind == .updateMany)
        #expect(!options.upsert)
    }

    @Test("arrayFilters in the third argument is carried")
    func testArrayFiltersCarried() throws {
        let query = "db.users.updateOne({}, {$set: {\"g.$[e].v\": 1}}, {arrayFilters: [{\"e.v\": {$gt: 5}}]})"
        guard case .write(_, _, _, _, let options) = try MongoShellParser.parse(query) else {
            Issue.record("Expected .write operation")
            return
        }
        #expect(options.arrayFilters == "[{\"e.v\": {$gt: 5}}]")
    }

    @Test("replaceOne and findOneAndUpdate report their own kind")
    func testWriteKinds() throws {
        guard case .write(let replaceKind, _, _, _, _) =
            try MongoShellParser.parse("db.u.replaceOne({}, {a: 1}, {upsert: true})") else {
            Issue.record("Expected .write operation")
            return
        }
        #expect(replaceKind == .replaceOne)

        guard case .write(let findKind, _, _, _, _) =
            try MongoShellParser.parse("db.u.findOneAndUpdate({}, {$set: {a: 1}}, {upsert: true})") else {
            Issue.record("Expected .write operation")
            return
        }
        #expect(findKind == .findOneAndUpdate)
    }

    @Test("a non-document third argument is rejected")
    func testNonDocumentOptionsThrows() {
        #expect(throws: MongoShellParseError.self) {
            try MongoShellParser.parse("db.users.updateOne({}, {$set: {a: 1}}, true)")
        }
    }
}
