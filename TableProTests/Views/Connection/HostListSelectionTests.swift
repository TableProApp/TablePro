//
//  HostListSelectionTests.swift
//  TableProTests
//
//  Regression coverage for issue #1293: deleting a host row must move
//  selection to the adjacent row so the list stays interactive.
//

import Foundation
@testable import TablePro
import Testing

@Suite("Host list selection after delete")
struct HostListSelectionTests {
    @Test("removing middle row selects row that takes its place")
    func removeMiddle() {
        let first = HostEntry(value: "a")
        let middle = HostEntry(value: "b")
        let last = HostEntry(value: "c")
        let result = HostListSelection.nextSelection(
            afterRemoving: [middle.id],
            from: [first, middle, last]
        )
        #expect(result == [last.id])
    }

    @Test("removing last row selects new last row")
    func removeLast() {
        let first = HostEntry(value: "a")
        let middle = HostEntry(value: "b")
        let last = HostEntry(value: "c")
        let result = HostListSelection.nextSelection(
            afterRemoving: [last.id],
            from: [first, middle, last]
        )
        #expect(result == [middle.id])
    }

    @Test("removing first row selects new first row")
    func removeFirst() {
        let first = HostEntry(value: "a")
        let second = HostEntry(value: "b")
        let result = HostListSelection.nextSelection(
            afterRemoving: [first.id],
            from: [first, second]
        )
        #expect(result == [second.id])
    }

    @Test("removing only entry returns empty selection")
    func removeOnly() {
        let only = HostEntry(value: "a")
        let result = HostListSelection.nextSelection(
            afterRemoving: [only.id],
            from: [only]
        )
        #expect(result.isEmpty)
    }

    @Test("removing multiple selects first remaining at removal index")
    func removeMultiple() {
        let first = HostEntry(value: "a")
        let middle = HostEntry(value: "b")
        let last = HostEntry(value: "c")
        let result = HostListSelection.nextSelection(
            afterRemoving: [middle.id, last.id],
            from: [first, middle, last]
        )
        #expect(result == [first.id])
    }

    @Test("removing nothing returns empty selection")
    func removeNothing() {
        let only = HostEntry(value: "a")
        let result = HostListSelection.nextSelection(
            afterRemoving: [],
            from: [only]
        )
        #expect(result.isEmpty)
    }

    @Test("selection ids that no longer exist are treated as no-op")
    func staleSelection() {
        let only = HostEntry(value: "a")
        let stale = UUID()
        let result = HostListSelection.nextSelection(
            afterRemoving: [stale],
            from: [only]
        )
        #expect(result.isEmpty)
    }
}
