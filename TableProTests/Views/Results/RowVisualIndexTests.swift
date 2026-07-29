//
//  RowVisualIndexTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("RowVisualIndex display-order mapping")
@MainActor
struct RowVisualIndexTests {
    @Test("an inserted row is marked at its display index, not its model index")
    func insertedRowMarkedAtDisplayIndex() {
        let index = RowVisualIndex()
        let changeManager = AnyChangeManager(DataChangeManager())
        let displayIDs: [RowID] = [.existing(0), .inserted(UUID()), .existing(2)]

        index.rebuild(from: changeManager, sortedIDs: displayIDs)

        #expect(index.visualState(for: 1).isInserted)
        #expect(!index.visualState(for: 0).isInserted)
        #expect(!index.visualState(for: 2).isInserted)
    }

    @Test("no inserted rows leaves every display index clean")
    func noInsertedRowsLeavesStateEmpty() {
        let index = RowVisualIndex()
        let changeManager = AnyChangeManager(DataChangeManager())
        let displayIDs: [RowID] = [.existing(0), .existing(1)]

        index.rebuild(from: changeManager, sortedIDs: displayIDs)

        #expect(index.visualState(for: 0) == .empty)
        #expect(index.visualState(for: 1) == .empty)
    }
}
