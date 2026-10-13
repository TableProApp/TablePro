//
//  ExecutionSlotTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

internal struct ExecutionSlotTests {
    private static let timing = PluginQueryTiming(total: 0.6)

    @Test("A tab that never ran draws no report")
    func neverRunTabDrawsNothing() {
        let slot = ExecutionSlot(isOffered: true, isRevealed: false, lastTiming: nil)
        #expect(slot.report == nil)
    }

    @Test("A revealed run draws the spinner, even over an earlier duration")
    func revealedRunDrawsTheSpinner() {
        let afterEarlierRun = ExecutionSlot(isOffered: true, isRevealed: true, lastTiming: Self.timing)
        let firstRun = ExecutionSlot(isOffered: true, isRevealed: true, lastTiming: nil)

        #expect(afterEarlierRun.report == .running)
        #expect(firstRun.report == .running)
    }

    @Test("A finished run keeps its duration until the next run is revealed")
    func finishedRunDrawsItsDuration() {
        let slot = ExecutionSlot(isOffered: true, isRevealed: false, lastTiming: Self.timing)

        #expect(slot.report == .lastRun(Self.timing))
    }

    @Test("A mode that does not offer the slot draws nothing, even while a run is revealed")
    func unofferedSlotDrawsNothing() {
        let slot = ExecutionSlot(isOffered: false, isRevealed: true, lastTiming: Self.timing)

        #expect(slot.report == nil)
    }
}
