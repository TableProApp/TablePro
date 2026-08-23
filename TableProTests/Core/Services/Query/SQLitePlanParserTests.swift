//
//  SQLitePlanParserTests.swift
//  TableProTests
//
//  Tests for parsing SQLite EXPLAIN QUERY PLAN rows into a QueryPlan tree. Shared by the
//  SQLite, Cloudflare D1 and libSQL drivers, which all return the same four columns.
//

import Foundation
@testable import TablePro
import Testing

@Suite("SQLite Plan Parser")
struct SQLitePlanParserTests {
    private let parser = SQLitePlanParser()

    @Test("Builds a tree from the id and parent columns")
    func buildsTreeFromParentIds() throws {
        let output = [
            "2\t0\t0\tSCAN users",
            "4\t2\t0\tSEARCH orders USING INDEX idx_customer",
        ].joined(separator: "\n")

        let plan = try #require(parser.parse(rawText: output))

        #expect(plan.rootNode.operation == "SCAN users")
        #expect(plan.rootNode.children.count == 1)
        #expect(plan.rootNode.children[0].operation == "SEARCH orders USING INDEX idx_customer")
    }

    @Test("Several children under one parent stay siblings")
    func keepsSiblingsFlat() throws {
        let output = [
            "1\t0\t0\tCOMPOUND QUERY",
            "2\t1\t0\tLEFT-MOST SUBQUERY",
            "3\t1\t0\tUNION ALL",
        ].joined(separator: "\n")

        let plan = try #require(parser.parse(rawText: output))

        #expect(plan.rootNode.operation == "COMPOUND QUERY")
        #expect(plan.rootNode.children.count == 2)
        #expect(plan.rootNode.children.allSatisfy { $0.children.isEmpty })
    }

    @Test("Several roots are wrapped in one synthetic node")
    func wrapsMultipleRoots() throws {
        let output = [
            "1\t0\t0\tSCAN users",
            "2\t0\t0\tSCAN roles",
        ].joined(separator: "\n")

        let plan = try #require(parser.parse(rawText: output))

        #expect(plan.rootNode.operation == "Query Plan")
        #expect(plan.rootNode.children.count == 2)
    }

    @Test("Nesting goes deeper than one level")
    func nestsDeeply() throws {
        let output = [
            "1\t0\t0\tCO-ROUTINE subquery",
            "2\t1\t0\tSCAN t1",
            "3\t2\t0\tUSE TEMP B-TREE FOR ORDER BY",
        ].joined(separator: "\n")

        let plan = try #require(parser.parse(rawText: output))

        #expect(plan.rootNode.children.count == 1)
        #expect(plan.rootNode.children[0].children.count == 1)
        #expect(plan.rootNode.children[0].children[0].operation == "USE TEMP B-TREE FOR ORDER BY")
    }

    @Test("A line that is not four columns becomes a flat detail node")
    func fallsBackForMalformedLines() throws {
        let plan = try #require(parser.parse(rawText: "SCAN users without columns"))
        #expect(plan.rootNode.operation == "SCAN users without columns")
    }

    @Test("Empty input has no plan")
    func rejectsEmptyInput() {
        #expect(parser.parse(rawText: "") == nil)
        #expect(parser.parse(rawText: "\n\n") == nil)
    }
}
