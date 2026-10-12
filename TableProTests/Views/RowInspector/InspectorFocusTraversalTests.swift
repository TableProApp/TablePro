//
//  InspectorFocusTraversalTests.swift
//  TableProTests
//
//  Tab between the inspector's fields is the list's own work, and a map takes no keyboard focus.
//  A geometry field opens on its map, so on a spatial table the field after it would be out of the
//  keyboard's reach unless Tab passes over the map.
//

import Foundation
@testable import TablePro
import Testing

@MainActor
struct InspectorFocusTraversalTests {
    private let name = UUID()
    private let shape = UUID()
    private let note = UUID()

    private var order: [UUID] {
        [name, shape, note]
    }

    private func destination(from current: UUID?, forward: Bool, skipping: Set<UUID> = []) -> UUID? {
        InspectorFieldListView.focusDestination(from: current, in: order, forward: forward, skipping: skipping)
    }

    @Test("Tab moves to the next field and Shift-Tab to the one before")
    func movesByOne() {
        #expect(destination(from: name, forward: true) == shape)
        #expect(destination(from: note, forward: false) == shape)
    }

    @Test("Tab passes a field showing a map")
    func passesAMapForward() {
        #expect(destination(from: name, forward: true, skipping: [shape]) == note)
    }

    @Test("Shift-Tab passes it too")
    func passesAMapBackward() {
        #expect(destination(from: note, forward: false, skipping: [shape]) == name)
    }

    @Test("Tab leaves the list at either end")
    func leavesAtTheEnds() {
        #expect(destination(from: note, forward: true) == nil)
        #expect(destination(from: name, forward: false) == nil)
    }

    @Test("Tab leaves the list when only a map is left to reach")
    func leavesWhenOnlyAMapRemains() {
        #expect(destination(from: shape, forward: true, skipping: [note]) == nil)
        #expect(destination(from: shape, forward: false, skipping: [name]) == nil)
    }

    @Test("With nothing focused, Tab starts at the first field that takes focus")
    func startsAtTheFirstFocusableField() {
        #expect(destination(from: nil, forward: true) == name)
        #expect(destination(from: nil, forward: false) == note)
        #expect(destination(from: nil, forward: true, skipping: [name]) == shape)
        #expect(destination(from: nil, forward: false, skipping: [note]) == shape)
    }

    @Test("A focused field the filter has hidden starts over")
    func aHiddenFieldStartsOver() {
        #expect(destination(from: UUID(), forward: true) == name)
    }

    @Test("An empty list has nowhere to go")
    func emptyList() {
        #expect(InspectorFieldListView.focusDestination(from: nil, in: [], forward: true, skipping: []) == nil)
    }

    // MARK: - Registry

    @Test("A field is passed over only while it reports no tab stop")
    func registryFollowsTheField() {
        let registry = InspectorTabStopRegistry()
        registry.record(false, for: shape)
        #expect(registry.fieldsWithoutTabStop == [shape])

        registry.record(true, for: shape)
        #expect(registry.fieldsWithoutTabStop.isEmpty)
    }

    /// Field ids are reissued on every selection change, so the registry would otherwise grow.
    @Test("Ids the list no longer shows are forgotten")
    func reissuedIdsAreForgotten() {
        let registry = InspectorTabStopRegistry()
        let previous = UUID()
        registry.record(false, for: previous)
        registry.record(false, for: shape)

        registry.forget(allBut: order)
        #expect(registry.fieldsWithoutTabStop == [shape])
    }
}
