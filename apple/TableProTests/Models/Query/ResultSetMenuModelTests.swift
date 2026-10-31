//
//  ResultSetMenuModelTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct ResultSetMenuModelTests {
    // A position rather than a name: "Result 2 of 4" read as the name of a result counted "Result 3" after a close.
    @Test("The title counts the results when there is more than one")
    func titleCountsResults() {
        let model = Self.make(count: 4, activeIndex: 1)

        #expect(model.title == "2 of 4")
    }

    @Test("A single result is named rather than counted")
    func singleResultIsNamed() {
        let model = Self.make(count: 1, activeIndex: 0)

        #expect(model.title == "Result 1")
    }

    @Test("A pinned result cannot be closed")
    func pinnedCannotClose() {
        let model = Self.make(count: 2, activeIndex: 0, pinnedIndices: [0])
        guard let active = model.activeEntry else {
            Issue.record("Expected an active entry")
            return
        }

        #expect(active.isPinned)
        #expect(model.canClose(active) == false)
    }

    @Test("Close Others is offered only when another result can actually go")
    func closeOthersNeedsAClosableSibling() {
        let onlyPinnedSiblings = Self.make(count: 2, activeIndex: 0, pinnedIndices: [0, 1])
        guard let active = onlyPinnedSiblings.activeEntry else {
            Issue.record("Expected an active entry")
            return
        }
        #expect(onlyPinnedSiblings.canCloseOthers(active) == false)

        let hasClosableSibling = Self.make(count: 2, activeIndex: 0, pinnedIndices: [0])
        guard let stillActive = hasClosableSibling.activeEntry else {
            Issue.record("Expected an active entry")
            return
        }
        #expect(hasClosableSibling.canCloseOthers(stillActive))
    }

    @Test("A lone result offers nothing to close beside it")
    func loneResultHasNoOthers() {
        let model = Self.make(count: 1, activeIndex: 0)
        guard let active = model.activeEntry else {
            Issue.record("Expected an active entry")
            return
        }

        #expect(model.canCloseOthers(active) == false)
    }

    @Test("Compare is offered only for a result that holds columns")
    func compareNeedsColumns() throws {
        let rows = Self.make(count: 2, activeIndex: 1, comparableIndices: [0, 1])
        let plan = Self.make(count: 2, activeIndex: 1, comparableIndices: [0])

        #expect(rows.canCompare(try #require(rows.activeEntry)))
        #expect(plan.canCompare(try #require(plan.activeEntry)) == false)
    }

    @Test("An empty model draws no control")
    func emptyModelIsEmpty() {
        let model = ResultSetMenuModel(entries: [], activeOrdinal: 0, total: 0)

        #expect(model.isEmpty)
        #expect(model.activeEntry == nil)
    }

    @Test("Tabs are offered from two results up to six, the HIG's limit for a tab view")
    func tabsNeedTwoToSixResults() {
        #expect(Self.make(count: 1, activeIndex: 0).offersTabs == false)
        #expect(Self.make(count: 2, activeIndex: 0).offersTabs)
        #expect(Self.make(count: 6, activeIndex: 0).offersTabs)
        #expect(Self.make(count: 7, activeIndex: 0).offersTabs == false)
    }

    @Test("Two results from one table get names that tell them apart")
    func duplicateLabelsAreNumbered() {
        let model = Self.make(labels: ["users", "orders", "users", "users"], activeIndex: 0)

        #expect(model.entries.map(model.displayLabel(of:)) == ["users", "orders", "users (2)", "users (3)"])
    }

    @Test("A long name is cut on a whole character, never inside an emoji")
    func truncationKeepsWholeCharacters() {
        let label = "Monthly revenue per region 📈 for Q3"
        let cut = ResultSetMenuModel.truncated(label, limit: 28)

        #expect(cut == "Monthly revenue per region 📈…")
        #expect(cut.unicodeScalars.contains("\u{FFFD}") == false)
        #expect(ResultSetMenuModel.truncated("orders", limit: 28) == "orders")
    }

    @Test("A tab's title is the disambiguated name, cut to fit")
    func tabTitleIsBounded() throws {
        let model = Self.make(labels: ["a_table_name_long_enough_to_need_cutting"], activeIndex: 0)
        let entry = try #require(model.entries.first)

        #expect(model.tabTitle(of: entry).count <= 25)
        #expect(model.tabTitle(of: entry).hasSuffix("…"))
    }

    private static func make(labels: [String], activeIndex: Int) -> ResultSetMenuModel {
        let entries = labels.enumerated().map { index, label in
            ResultSetMenuEntry(
                id: UUID(),
                label: label,
                isPinned: false,
                isActive: index == activeIndex,
                ordinal: index + 1,
                isComparable: true
            )
        }
        return ResultSetMenuModel(entries: entries, activeOrdinal: activeIndex + 1, total: labels.count)
    }

    private static func make(
        count: Int,
        activeIndex: Int,
        pinnedIndices: Set<Int> = [],
        comparableIndices: Set<Int>? = nil
    ) -> ResultSetMenuModel {
        let entries = (0 ..< count).map { index in
            ResultSetMenuEntry(
                id: UUID(),
                label: "Result \(index + 1)",
                isPinned: pinnedIndices.contains(index),
                isActive: index == activeIndex,
                ordinal: index + 1,
                isComparable: comparableIndices.map { $0.contains(index) } ?? true
            )
        }
        return ResultSetMenuModel(
            entries: entries,
            activeOrdinal: activeIndex + 1,
            total: count
        )
    }
}
