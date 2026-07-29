//
//  RestoreWindowPlanTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("RestoreWindowPlan")
struct RestoreWindowPlanTests {
    @Test("Selected tab is the first tab: front is the first tab")
    func selectedIsFirst() {
        let first = UUID()
        let remaining = [UUID(), UUID()]
        let front = RestoreWindowPlan.resolveFrontTabId(
            remainingTabIds: remaining, firstTabId: first, selectedId: first
        )
        #expect(front == first)
    }

    @Test("Selected tab is one of the remaining tabs: front is that tab")
    func selectedIsRemaining() {
        let first = UUID()
        let target = UUID()
        let remaining = [UUID(), target, UUID()]
        let front = RestoreWindowPlan.resolveFrontTabId(
            remainingTabIds: remaining, firstTabId: first, selectedId: target
        )
        #expect(front == target)
    }

    @Test("Selected id matches neither: falls back to the first tab")
    func selectedMatchesNeither() {
        let first = UUID()
        let remaining = [UUID()]
        let front = RestoreWindowPlan.resolveFrontTabId(
            remainingTabIds: remaining, firstTabId: first, selectedId: UUID()
        )
        #expect(front == first)
    }

    @Test("Nil selected id: falls back to the first tab")
    func selectedNil() {
        let first = UUID()
        let front = RestoreWindowPlan.resolveFrontTabId(
            remainingTabIds: [UUID()], firstTabId: first, selectedId: nil
        )
        #expect(front == first)
    }
}
