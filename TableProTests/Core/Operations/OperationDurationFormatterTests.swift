//
//  OperationDurationFormatterTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("OperationDurationFormatter")
struct OperationDurationFormatterTests {
    @Test("Under a minute reads in seconds")
    func secondsOnly() {
        #expect(OperationDurationFormatter.string(from: .seconds(51)) == "51s")
    }

    @Test("Seconds are zero padded inside a minute so the column does not jump")
    func minutesPadSeconds() {
        #expect(OperationDurationFormatter.string(from: .seconds(68)) == "1m 08s")
        #expect(OperationDurationFormatter.string(from: .seconds(192)) == "3m 12s")
    }

    @Test("An hour drops seconds rather than printing three units")
    func hoursDropSeconds() {
        #expect(OperationDurationFormatter.string(from: .seconds(3840)) == "1h 04m")
    }

    @Test("Fractional seconds are never shown")
    func noFractionalSeconds() {
        #expect(OperationDurationFormatter.string(from: .milliseconds(192_437)) == "3m 12s")
    }

    @Test("A negative duration cannot produce a negative reading")
    func negativeIsClamped() {
        #expect(OperationDurationFormatter.string(from: .seconds(-5)) == "0s")
    }
}
