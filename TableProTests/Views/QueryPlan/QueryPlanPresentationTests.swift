//
//  QueryPlanPresentationTests.swift
//  TableProTests
//
//  What the plan pane shows: a parsed tree, the raw output, or an explicit empty state. A nil
//  plan used to fall through to a blank rectangle.
//

import Foundation
@testable import TablePro
import Testing

@Suite("Query Plan Presentation")
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
        #expect(QueryPlanViewMode.allCases.count == 3)
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

    @Test("History compares nodes only when both plans parsed")
    func historyRequiresTwoParsedPlans() {
        let structured = QueryPlanHistoryComparisonPresentation.resolve(
            previousPlan: samplePlan,
            previousRawText: "older",
            currentPlan: samplePlan,
            currentRawText: "current"
        )
        #expect(structured.kind == .structured)

        let unparsedBaseline = QueryPlanHistoryComparisonPresentation.resolve(
            previousPlan: nil,
            previousRawText: "older raw",
            currentPlan: samplePlan,
            currentRawText: "current"
        )
        #expect(unparsedBaseline.kind == .rawOnly)

        let unparsedCurrent = QueryPlanHistoryComparisonPresentation.resolve(
            previousPlan: samplePlan,
            previousRawText: "older",
            currentPlan: nil,
            currentRawText: "current raw"
        )
        #expect(unparsedCurrent.kind == .rawOnly)
    }

    @Test("History skips baseline parsing when current plan is unavailable")
    func historySkipsUnneededBaselineParsing() {
        #expect(!QueryPlanHistoryComparisonDecision.requiresBaselineParsing(currentPlan: nil))
        #expect(QueryPlanHistoryComparisonDecision.requiresBaselineParsing(currentPlan: samplePlan))
    }

    @Test("Node change accessibility includes value changes")
    func nodeChangeAccessibilityValue() {
        let change = QueryPlanNodeChange(
            kind: .modified,
            semanticPathID: "root",
            operation: "Seq Scan",
            relation: "Track",
            schema: nil,
            alias: nil,
            valueChanges: [
                QueryPlanNodeValueChange(
                    category: .metric,
                    name: "Estimated rows",
                    previousValue: "10",
                    currentValue: "20"
                ),
                QueryPlanNodeValueChange(
                    category: .property,
                    name: "Filter",
                    previousValue: nil,
                    currentValue: "active"
                ),
            ]
        )

        #expect(
            QueryPlanHistoryNodeChangeAccessibility.value(change) ==
                "Estimated rows: 10 → 20, Filter: – → active"
        )
    }

    @Test("Raw history comparison bounds text rendered in the sheet")
    func boundsHistoryRawText() {
        let limit = QueryPlanHistoryRawText.maximumDisplayedUTF16Length
        let truncationMarker = "\n\n… " + String(localized: "Output truncated for display")
        let oversized = String(repeating: "x", count: limit * 2)
        let displayed = QueryPlanHistoryRawText.bounded(oversized)

        #expect((displayed as NSString).substring(to: limit) == String(repeating: "x", count: limit))
        #expect(displayed.hasSuffix(truncationMarker))
        #expect(displayed.count < oversized.count)
        #expect(QueryPlanHistoryRawText.bounded("short plan") == "short plan")

        let emoji = String(repeating: "😀", count: (limit / 2) + 1)
        let emojiDisplay = QueryPlanHistoryRawText.bounded(emoji)
        #expect(emojiDisplay != emoji)
        #expect(emojiDisplay.hasSuffix(truncationMarker))

        let combining = String(repeating: "e\u{301}", count: (limit / 2) + 1)
        let combiningDisplay = QueryPlanHistoryRawText.bounded(combining)
        #expect(combiningDisplay != combining)
        #expect(combiningDisplay.hasSuffix(truncationMarker))
    }
}
