//
//  CockroachDBPlanParserTests.swift
//  TableProTests
//
//  Tests for parsing CockroachDB EXPLAIN text output into a QueryPlan tree.
//

import Foundation
@testable import TablePro
import Testing

@Suite("CockroachDB Plan Parser")
struct CockroachDBPlanParserTests {
    private let parser = CockroachDBPlanParser()

    private let explainOutput = [
        "distribution: local",
        "vectorized: true",
        "",
        "• sort",
        "│ estimated row count: 333",
        "│ order: +name",
        "│",
        "└── • filter",
        "    │ estimated row count: 333",
        "    │ filter: age > 18",
        "    │",
        "    └── • scan",
        "          estimated row count: 1,000 (100% of the table)",
        "          table: users@users_pkey",
        "          spans: FULL SCAN",
    ].joined(separator: "\n")

    @Test("Parses node tree with correct depth nesting")
    func parsesNodeTree() throws {
        let plan = try #require(parser.parse(rawText: explainOutput))
        #expect(plan.rootNode.operation == "sort")
        #expect(plan.rootNode.children.count == 1)

        let filter = plan.rootNode.children[0]
        #expect(filter.operation == "filter")
        #expect(filter.children.count == 1)

        let scan = filter.children[0]
        #expect(scan.operation == "scan")
        #expect(scan.children.isEmpty)
    }

    @Test("Extracts estimated row count")
    func extractsEstimatedRowCount() throws {
        let plan = try #require(parser.parse(rawText: explainOutput))
        #expect(plan.rootNode.estimatedRows == 333)

        let scan = plan.rootNode.children[0].children[0]
        #expect(scan.estimatedRows == 1_000)
    }

    @Test("Extracts table name into relation, stripping index suffix")
    func extractsRelation() throws {
        let plan = try #require(parser.parse(rawText: explainOutput))
        let scan = plan.rootNode.children[0].children[0]
        #expect(scan.relation == "users")
    }

    @Test("Keeps non-row-count properties on the node")
    func keepsOtherProperties() throws {
        let plan = try #require(parser.parse(rawText: explainOutput))
        #expect(plan.rootNode.properties["order"] == "+name")
        let scan = plan.rootNode.children[0].children[0]
        #expect(scan.properties["spans"] == "FULL SCAN")
    }

    @Test("Parses planning and execution time from EXPLAIN ANALYZE")
    func parsesTimingHeader() throws {
        let analyzeOutput = [
            "planning time: 1ms",
            "execution time: 5ms",
            "distribution: local",
            "",
            "• scan",
            "  estimated row count: 10",
            "  actual row count: 10",
            "  table: users@users_pkey",
        ].joined(separator: "\n")

        let plan = try #require(parser.parse(rawText: analyzeOutput))
        #expect(plan.planningTime == 1.0)
        #expect(plan.executionTime == 5.0)
        #expect(plan.rootNode.operation == "scan")
        #expect(plan.rootNode.actualRows == 10)
    }

    @Test("Returns nil for output without nodes")
    func returnsNilForEmptyOutput() {
        #expect(parser.parse(rawText: "") == nil)
        #expect(parser.parse(rawText: "distribution: local\nvectorized: true") == nil)
    }

    @Test("Factory returns CockroachDB parser for .cockroachdb")
    func factoryReturnsCockroachParser() {
        #expect(QueryPlanParserFactory.parser(for: .cockroachdb) is CockroachDBPlanParser)
    }
}
