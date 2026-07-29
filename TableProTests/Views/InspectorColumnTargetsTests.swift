//
//  InspectorColumnTargetsTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("InspectorColumnTargets")
struct InspectorColumnTargetsTests {
    @Test("Delete menu targets the whole selection only when the clicked column is inside it")
    func deleteMenuSelection() {
        #expect(InspectorColumnTargets.deleteMenuSelection(
            clicked: 1, fullySelected: IndexSet([1, 2, 3])) == [1, 2, 3])
        #expect(InspectorColumnTargets.deleteMenuSelection(
            clicked: 5, fullySelected: IndexSet([1, 2, 3])) == [5])
        #expect(InspectorColumnTargets.deleteMenuSelection(
            clicked: 2, fullySelected: IndexSet([2])) == [2])
        #expect(InspectorColumnTargets.deleteMenuSelection(
            clicked: 0, fullySelected: IndexSet()) == [0])
    }

    @Test("Delete targets prefer the explicit list and fall back to the selection, filtered to range")
    func deleteTargets() {
        #expect(InspectorColumnTargets.deleteTargets(
            explicit: [3, 1], fullySelected: IndexSet([9]), columnCount: 5) == [1, 3])
        #expect(InspectorColumnTargets.deleteTargets(
            explicit: nil, fullySelected: IndexSet([0, 2]), columnCount: 5) == [0, 2])
        #expect(InspectorColumnTargets.deleteTargets(
            explicit: [1, 99], fullySelected: IndexSet(), columnCount: 3) == [1])
    }

    @Test("Insert anchor prefers the clicked column, then the selection bound, then the edge")
    func insertAnchor() {
        #expect(InspectorColumnTargets.insertAnchor(
            clicked: 2, fullySelected: IndexSet([0, 4]), columnCount: 5, toRight: true) == 2)
        #expect(InspectorColumnTargets.insertAnchor(
            clicked: nil, fullySelected: IndexSet([1, 3]), columnCount: 5, toRight: false) == 1)
        #expect(InspectorColumnTargets.insertAnchor(
            clicked: nil, fullySelected: IndexSet([1, 3]), columnCount: 5, toRight: true) == 3)
        #expect(InspectorColumnTargets.insertAnchor(
            clicked: nil, fullySelected: IndexSet(), columnCount: 5, toRight: false) == 0)
        #expect(InspectorColumnTargets.insertAnchor(
            clicked: nil, fullySelected: IndexSet(), columnCount: 5, toRight: true) == 4)
        #expect(InspectorColumnTargets.insertAnchor(
            clicked: 3, fullySelected: IndexSet(), columnCount: 0, toRight: false) == nil)
    }
}
