//
//  ResultSetMenuModelTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct ResultSetMenuModelTests {
    /// The count is what the deleted strip showed at a glance and a closed menu cannot. Carrying it
    /// in the button's own title is the whole mitigation, so it is worth a test.
    @Test("The title counts the results when there is more than one")
    func titleCountsResults() {
        let model = Self.make(count: 4, activeIndex: 1)

        #expect(model.title == "Result 2 of 4")
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

    @Test("An empty model draws no control")
    func emptyModelIsEmpty() {
        let model = ResultSetMenuModel(entries: [], activeOrdinal: 0, total: 0)

        #expect(model.isEmpty)
        #expect(model.activeEntry == nil)
    }

    private static func make(
        count: Int,
        activeIndex: Int,
        pinnedIndices: Set<Int> = []
    ) -> ResultSetMenuModel {
        let entries = (0 ..< count).map { index in
            ResultSetMenuEntry(
                id: UUID(),
                label: "Result \(index + 1)",
                isPinned: pinnedIndices.contains(index),
                isActive: index == activeIndex,
                ordinal: index + 1
            )
        }
        return ResultSetMenuModel(
            entries: entries,
            activeOrdinal: activeIndex + 1,
            total: count
        )
    }
}
