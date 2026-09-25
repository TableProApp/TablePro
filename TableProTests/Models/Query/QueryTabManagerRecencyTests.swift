//
//  QueryTabManagerRecencyTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
struct QueryTabManagerRecencyTests {
    /// A selection is recorded once the main queue turn it happened in has finished.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(20))
    }

    private func makeManager(tabCount: Int) async -> QueryTabManager {
        let manager = QueryTabManager()
        manager.isFrontmost = true
        for index in 0..<tabCount {
            manager.addTab(title: "Tab \(index + 1)")
        }
        await settle()
        return manager
    }

    private func sequence(of tab: QueryTab, in manager: QueryTabManager) -> UInt64 {
        manager.activationSequence[tab.id] ?? 0
    }

    @Test("Selecting a tab records it after every tab selected before it")
    func selectionIsRecordedInOrder() async throws {
        let manager = await makeManager(tabCount: 4)
        let first = try #require(manager.tabs.first)
        let second = manager.tabs[1]

        manager.selectedTabId = second.id
        await settle()
        manager.selectedTabId = first.id
        await settle()

        #expect(sequence(of: first, in: manager) > sequence(of: second, in: manager))
        #expect(sequence(of: second, in: manager) > 0)
    }

    /// Opening a table into another connection brings that connection forward and then selects the
    /// new tab in the same turn, so the tab it was showing is never drawn.
    @Test("A tab selected and replaced within one turn is never recorded")
    func transientSelectionIsNotRecorded() async throws {
        let manager = await makeManager(tabCount: 3)
        let first = try #require(manager.tabs.first)
        let second = manager.tabs[1]

        manager.selectedTabId = first.id
        manager.selectedTabId = second.id
        await settle()

        #expect(manager.activationSequence[first.id] == nil)
        #expect(sequence(of: second, in: manager) > 0)
    }

    @Test("Writing the selection it already has records nothing new")
    func reselectingTheSameTabIsNotAUse() async throws {
        let manager = await makeManager(tabCount: 2)
        let selected = try #require(manager.selectedTab)
        let before = sequence(of: selected, in: manager)

        manager.selectedTabId = selected.id
        await settle()

        #expect(sequence(of: selected, in: manager) == before)
    }

    @Test("Editing a tab's content is not a use of it")
    func mutatingContentRecordsNothing() async throws {
        let manager = await makeManager(tabCount: 2)
        let before = manager.activationSequence

        manager.tabs[0].title = "Renamed"
        await settle()

        #expect(manager.activationSequence == before)
    }

    @Test("A closed tab leaves the record, and the neighbour the close lands on joins it")
    func closingPrunesAndRecordsTheSuccessor() async throws {
        let manager = await makeManager(tabCount: 3)
        let middle = try #require(manager.tabs.dropFirst().first)
        let last = try #require(manager.tabs.last)
        manager.selectedTabId = middle.id
        await settle()
        let beforeClose = sequence(of: middle, in: manager)

        manager.closeTab(id: middle.id)
        await settle()

        #expect(manager.activationSequence[middle.id] == nil)
        #expect(sequence(of: last, in: manager) > beforeClose)
    }

    /// A restore that finishes for a connection the window is not showing selects a tab nobody has
    /// seen. Recorded, it would be where the next Control-Tab went instead of the tab the user left.
    @Test("A selection made while the connection is in the background is not a use")
    func backgroundSelectionIsNotRecorded() async throws {
        let manager = await makeManager(tabCount: 2)
        let first = try #require(manager.tabs.first)
        let before = manager.activationSequence
        manager.isFrontmost = false

        manager.selectedTabId = first.id
        await settle()

        #expect(manager.activationSequence == before)
    }

    @Test("Coming to the front records the tab the connection is showing")
    func comingToTheFrontRecordsTheSelection() async throws {
        let manager = await makeManager(tabCount: 2)
        let first = try #require(manager.tabs.first)
        manager.isFrontmost = false
        manager.selectedTabId = first.id
        let other = await makeManager(tabCount: 1)

        manager.isFrontmost = true
        await settle()

        #expect(sequence(of: first, in: manager) > (other.activationSequence.values.max() ?? 0))
    }

    @Test("Going to the back and front again within one turn records nothing")
    func flickerRecordsNothing() async throws {
        let manager = await makeManager(tabCount: 2)
        let before = manager.activationSequence

        manager.isFrontmost = false
        let first = try #require(manager.tabs.first)
        manager.selectedTabId = first.id
        manager.isFrontmost = true
        manager.isFrontmost = false
        await settle()

        #expect(manager.activationSequence == before)
    }

    /// A per-manager counter would pass a weaker version of this: each manager's own numbers still
    /// order its own tabs. Only a shared counter lets one connection's fresh tab outrank another
    /// connection's many older selections, which is what ordering a whole window needs.
    @Test("Two tab managers draw from one sequence, so a window can order their tabs together")
    func sequenceIsSharedAcrossManagers() async throws {
        let one = await makeManager(tabCount: 1)
        let two = await makeManager(tabCount: 3)
        for tab in two.tabs {
            two.selectedTabId = tab.id
            await settle()
        }
        let firstTab = try #require(one.tabs.first)
        one.isFrontmost = false

        one.isFrontmost = true
        await settle()

        #expect(sequence(of: firstTab, in: one) > (two.activationSequence.values.max() ?? 0))
    }

    /// The rail switches a connection's database before it selects the tab that database holds, and
    /// the tab shown while the switch runs is only a waypoint.
    @Test("A held record skips the tab passed through and records the one landed on")
    func deferredRecordSkipsTheWaypoint() async throws {
        let manager = await makeManager(tabCount: 3)
        let waypoint = manager.tabs[0]
        let landing = manager.tabs[1]
        manager.defersActivationRecord = true

        manager.selectedTabId = waypoint.id
        await settle()
        manager.selectedTabId = landing.id
        manager.defersActivationRecord = false
        await settle()

        #expect(manager.activationSequence[waypoint.id] == nil)
        #expect(sequence(of: landing, in: manager) > 0)
    }
}
