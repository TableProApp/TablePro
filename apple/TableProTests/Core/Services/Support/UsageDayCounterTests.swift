//
//  UsageDayCounterTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
struct UsageDayCounterTests {
    /// UTC+7, so a UTC timestamp near midnight lands on a different local day than its UTC date.
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 7 * 3_600) ?? .gmt
        return calendar
    }()

    private func date(_ text: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: text))
    }

    @Test("A day counts once however often the app is used that day")
    func sameDayCountsOnce() throws {
        let suite = try EphemeralDefaults()
        let counter = UsageDayCounter(defaults: suite.defaults, calendar: calendar)

        try counter.recordUse(at: date("2026-11-02T01:00:00Z"))
        try counter.recordUse(at: date("2026-11-02T09:30:00Z"))
        try counter.recordUse(at: date("2026-11-02T16:59:00Z"))

        #expect(counter.days == 1)
    }

    @Test("Each new day of use adds one, however many days were skipped")
    func newDaysAdd() throws {
        let suite = try EphemeralDefaults()
        let counter = UsageDayCounter(defaults: suite.defaults, calendar: calendar)

        try counter.recordUse(at: date("2026-11-02T03:00:00Z"))
        try counter.recordUse(at: date("2026-11-03T03:00:00Z"))
        try counter.recordUse(at: date("2026-11-20T03:00:00Z"))

        #expect(counter.days == 3)
    }

    @Test("The day turns at local midnight, not at UTC midnight")
    func dayTurnsAtLocalMidnight() throws {
        let suite = try EphemeralDefaults()
        let counter = UsageDayCounter(defaults: suite.defaults, calendar: calendar)

        // 23:59 and 00:01 local, both on 2 November in UTC.
        try counter.recordUse(at: date("2026-11-02T16:59:00Z"))
        try counter.recordUse(at: date("2026-11-02T17:01:00Z"))

        #expect(counter.days == 2)
    }

    @Test("The count is read back by a new counter on the same defaults")
    func countPersists() throws {
        let suite = try EphemeralDefaults()
        let first = UsageDayCounter(defaults: suite.defaults, calendar: calendar)
        try first.recordUse(at: date("2026-11-02T03:00:00Z"))
        try first.recordUse(at: date("2026-11-03T03:00:00Z"))

        let second = UsageDayCounter(defaults: suite.defaults, calendar: calendar)
        try second.recordUse(at: date("2026-11-03T08:00:00Z"))

        #expect(second.days == 2)
    }
}
