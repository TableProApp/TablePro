//
//  QueryPlanPresentationTests.swift
//  TableProTests
//
//  What the plan pane shows: a parsed tree, the raw output, or an explicit empty state. A nil
//  plan used to fall through to a blank rectangle.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct QueryPlanPresentationTests {
    private var samplePlan: QueryPlan {
        QueryPlan(
            rootNode: QueryPlanNode(
                operation: "Seq Scan",
                relation: nil, schema: nil, alias: nil,
                estimatedStartupCost: nil, estimatedTotalCost: 1,
                estimatedRows: nil, estimatedWidth: nil,
                actualStartupTime: nil, actualTotalTime: nil,
                actualRows: nil, actualLoops: nil,
                properties: [:], children: []
            ),
            planningTime: nil,
            executionTime: nil,
            rawText: "Seq Scan"
        )
    }

    @Test("A parsed plan wins over the raw text")
    func prefersParsedPlan() {
        let presentation = QueryPlanPresentation.resolve(plan: samplePlan, rawText: "Seq Scan")
        #expect(presentation.kind == .parsed)
        #expect(presentation.plan != nil)
        #expect(presentation.rawText == nil)
    }

    @Test("Unparsed output falls back to raw rather than a blank pane")
    func fallsBackToRaw() {
        let presentation = QueryPlanPresentation.resolve(plan: nil, rawText: "some driver output")
        #expect(presentation.kind == .rawOnly)
        #expect(presentation.rawText == "some driver output")
        #expect(presentation.plan == nil)
    }

    @Test("Nothing at all resolves to the empty state")
    func resolvesEmpty() {
        #expect(QueryPlanPresentation.resolve(plan: nil, rawText: "").kind == .empty)
        #expect(QueryPlanPresentation.resolve(plan: nil, rawText: "   \n  ").kind == .empty)
    }

    @Test("Raw output is trimmed before display")
    func trimsRawOutput() {
        let presentation = QueryPlanPresentation.resolve(plan: nil, rawText: "\n  plan text  \n")
        #expect(presentation.rawText == "plan text")
    }

    @Test("Every view mode has a localized title")
    func modesAreTitled() {
        for mode in QueryPlanViewMode.allCases {
            #expect(!mode.title.isEmpty)
        }
        #expect(QueryPlanViewMode.allCases.count == 5)
        #expect(QueryPlanViewMode.allCases.contains(.compare))
        #expect(QueryPlanViewMode.allCases.contains(.output))
    }

    @Test("A parsed plan offers Output only when its statement printed")
    func parsedPlanOffersOutputWithOutput() {
        #expect(QueryPlanViewMode.available(for: .parsed, canCompare: false, hasOutput: false) == [.diagram, .tree, .raw])
        #expect(QueryPlanViewMode.available(for: .parsed, canCompare: false, hasOutput: true)
            == [.diagram, .tree, .raw, .output])
        #expect(QueryPlanViewMode.available(for: .parsed, canCompare: true, hasOutput: true)
            == [.diagram, .tree, .raw, .compare, .output])
    }

    // PostgreSQL's typed EXPLAIN ANALYZE is text, which no parser reads, and it is the one that runs the statement.
    @Test("A plan the app could not read still offers Output beside Raw when its statement printed", arguments: [
        QueryPlanPresentation.Kind.rawOnly, .empty
    ])
    func unreadPlanOffersOutputWithOutput(kind: QueryPlanPresentation.Kind) {
        #expect(QueryPlanViewMode.available(for: kind, canCompare: true, hasOutput: false) == [.raw])
        #expect(QueryPlanViewMode.available(for: kind, canCompare: true, hasOutput: true) == [.raw, .output])
    }

    // The mode belongs to the editor tab, so Output chosen on one plan is still chosen when the next has none.
    @Test("A chosen mode the plan does not offer shows the plan's first mode instead")
    func chosenModeFallsBackWhenNotOffered() {
        #expect(QueryPlanViewMode.effective(.output, among: [.diagram, .tree, .raw]) == .diagram)
        #expect(QueryPlanViewMode.effective(.output, among: [.raw]) == .raw)
        #expect(QueryPlanViewMode.effective(.compare, among: [.diagram, .tree, .raw, .output]) == .diagram)
        #expect(QueryPlanViewMode.effective(.tree, among: [.diagram, .tree, .raw]) == .tree)
        #expect(QueryPlanViewMode.effective(.output, among: [.raw, .output]) == .output)
    }

    @Test("A plan's result set keeps what its statement printed")
    @MainActor
    func explainResultSetCarriesTheOutput() {
        let printed = PluginServerOutput(lines: ["NOTICE:  step 1 done"], isTruncated: false)
        let plan = ExplainResultSetFactory.make(
            rawText: "Seq Scan", plan: nil, sql: "EXPLAIN ANALYZE SELECT demo()", executionTime: 0.1, serverOutput: printed
        )
        #expect(plan.serverOutput == printed)
    }

    @Test("An explain result set is recognised by its raw text, not by a parsed plan")
    @MainActor
    func recognisesExplainResultSet() {
        let unparsed = ExplainResultSetFactory.make(
            rawText: "raw", plan: nil, sql: "EXPLAIN SELECT 1", executionTime: 0.1
        )
        #expect(unparsed.isExplainResult)
        #expect(unparsed.queryPlan == nil)
        #expect(unparsed.baseQuery == "EXPLAIN SELECT 1")

        let ordinary = ResultSet(label: "Result")
        #expect(!ordinary.isExplainResult)
    }
}
