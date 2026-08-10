//
//  RestoreWindowPlanTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("RestoreWindowPlan")
struct RestoreWindowPlanTests {
    @Test("Selected tab is one this window kept: this window comes to the front")
    func selectedIsOwn() {
        let own = UUID()
        let front = RestoreWindowPlan.resolveFrontGroup(
            ownTabIds: [own],
            orphanedGroups: [(windowGroupIndex: 1, tabIds: [UUID()])],
            selectedId: own
        )
        #expect(front == .own)
    }

    @Test("Selected tab belongs to a reopened group: that group comes to the front")
    func selectedIsOrphaned() {
        let target = UUID()
        let front = RestoreWindowPlan.resolveFrontGroup(
            ownTabIds: [UUID()],
            orphanedGroups: [
                (windowGroupIndex: 1, tabIds: [UUID()]),
                (windowGroupIndex: 2, tabIds: [UUID(), target]),
            ],
            selectedId: target
        )
        #expect(front == .orphaned(windowGroupIndex: 2))
    }

    @Test("Selected id matches nothing being restored: this window comes to the front")
    func selectedMatchesNeither() {
        let front = RestoreWindowPlan.resolveFrontGroup(
            ownTabIds: [UUID()],
            orphanedGroups: [(windowGroupIndex: 1, tabIds: [UUID()])],
            selectedId: UUID()
        )
        #expect(front == .own)
    }

    @Test("Nothing was selected: this window comes to the front")
    func selectedNil() {
        let front = RestoreWindowPlan.resolveFrontGroup(
            ownTabIds: [UUID()],
            orphanedGroups: [(windowGroupIndex: 1, tabIds: [UUID()])],
            selectedId: nil
        )
        #expect(front == .own)
    }
}
