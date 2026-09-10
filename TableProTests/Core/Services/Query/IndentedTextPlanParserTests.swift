//
//  IndentedTextPlanParserTests.swift
//  TableProTests
//
//  Tests for parsing indentation-based EXPLAIN output (ClickHouse, DuckDB) into a QueryPlan tree.
//

import Foundation
@testable import TablePro
import Testing

@Suite("Indented Text Plan Parser")
struct IndentedTextPlanParserTests {
    private let parser = IndentedTextPlanParser()

    @Test("Indentation becomes nesting")
    func nestsByIndentation() throws {
        let output = [
            "Expression ((Projection + Before ORDER BY))",
            "  Aggregating",
            "    ReadFromMergeTree (default.events)",
        ].joined(separator: "\n")

        let plan = try #require(parser.parse(rawText: output))

        #expect(plan.rootNode.operation == "Expression ((Projection + Before ORDER BY))")
        #expect(plan.rootNode.children.count == 1)
        #expect(plan.rootNode.children[0].operation == "Aggregating")
        #expect(plan.rootNode.children[0].children[0].operation == "ReadFromMergeTree (default.events)")
    }

    @Test("Lines at the same indentation stay siblings")
    func keepsSameIndentationFlat() throws {
        let output = [
            "Union",
            "  Expression",
            "  Expression",
        ].joined(separator: "\n")

        let plan = try #require(parser.parse(rawText: output))

        #expect(plan.rootNode.children.count == 2)
        #expect(plan.rootNode.children.allSatisfy { $0.children.isEmpty })
    }

    @Test("Several roots are wrapped in one synthetic node")
    func wrapsMultipleRoots() throws {
        let plan = try #require(parser.parse(rawText: "Projection\nAggregate"))

        #expect(plan.rootNode.operation == "Query Plan")
        #expect(plan.rootNode.children.count == 2)
    }

    @Test("Dedenting closes the deeper level")
    func dedentClosesLevel() throws {
        let output = [
            "Sort",
            "  Filter",
            "    Scan",
            "  Limit",
        ].joined(separator: "\n")

        let plan = try #require(parser.parse(rawText: output))

        #expect(plan.rootNode.children.count == 2)
        #expect(plan.rootNode.children[0].operation == "Filter")
        #expect(plan.rootNode.children[0].children.count == 1)
        #expect(plan.rootNode.children[1].operation == "Limit")
    }

    @Test("A single line is the whole plan")
    func parsesSingleLine() throws {
        let plan = try #require(parser.parse(rawText: "ReadFromStorage (SystemNumbers)"))
        #expect(plan.rootNode.operation == "ReadFromStorage (SystemNumbers)")
        #expect(plan.rootNode.children.isEmpty)
    }

    @Test("Empty input has no plan")
    func rejectsEmptyInput() {
        #expect(parser.parse(rawText: "") == nil)
        #expect(parser.parse(rawText: "\n\n") == nil)
    }
}
