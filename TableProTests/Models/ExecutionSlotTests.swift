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

    @Test("A tab that never ran draws no report and no separator, with or without a readout")
    func neverRunTabDrawsNothing() {
        for followsReadout in [false, true] {
            let slot = ExecutionSlot(isOffered: true, followsReadout: followsReadout, isRevealed: false, lastTiming: nil)
            #expect(slot.report == nil)
            #expect(!slot.leadsWithSeparator)
        }
    }

    @Test("A revealed run draws the spinner, set off by a separator only after a readout")
    func revealedRunDrawsTheSpinner() {
        let alone = ExecutionSlot(isOffered: true, followsReadout: false, isRevealed: true, lastTiming: Self.timing)
        let afterReadout = ExecutionSlot(isOffered: true, followsReadout: true, isRevealed: true, lastTiming: nil)

        #expect(alone.report == .running)
        #expect(!alone.leadsWithSeparator)
        #expect(afterReadout.report == .running)
        #expect(afterReadout.leadsWithSeparator)
    }

    @Test("A finished run keeps its duration until the next run is revealed")
    func finishedRunDrawsItsDuration() {
        let slot = ExecutionSlot(isOffered: true, followsReadout: true, isRevealed: false, lastTiming: Self.timing)

        #expect(slot.report == .lastRun(Self.timing))
        #expect(slot.leadsWithSeparator)
    }

    @Test("A mode that does not offer the slot draws nothing, even while a run is revealed")
    func unofferedSlotDrawsNothing() {
        let slot = ExecutionSlot(isOffered: false, followsReadout: true, isRevealed: true, lastTiming: Self.timing)

        #expect(slot.report == nil)
        #expect(!slot.leadsWithSeparator)
    }
}
