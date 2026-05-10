//
//  DateFilterTests.swift
//  TableProTests
//
//  Tests for DateFilter enum used by history queries.
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("DateFilter")
struct DateFilterTests {
    @Test(".all returns nil startDate")
    func allReturnsNilStartDate() {
        #expect(DateFilter.all.startDate == nil)
    }

    @Test(".today returns start of current day")
    func todayReturnsStartOfDay() {
        let startDate = DateFilter.today.startDate
        #expect(startDate != nil)
        let expected = Calendar.current.startOfDay(for: Date())
        #expect(startDate == expected)
    }

    @Test(".thisWeek returns approximately 7 days ago")
    func thisWeekReturns7DaysAgo() {
        let startDate = DateFilter.thisWeek.startDate
        #expect(startDate != nil)
        let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
        let diff = abs(startDate!.timeIntervalSince(sevenDaysAgo))
        #expect(diff < 2.0) // Within 2 seconds tolerance
    }

    @Test(".thisMonth returns approximately 30 days ago")
    func thisMonthReturns30DaysAgo() {
        let startDate = DateFilter.thisMonth.startDate
        #expect(startDate != nil)
        let thirtyDaysAgo = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        let diff = abs(startDate!.timeIntervalSince(thirtyDaysAgo))
        #expect(diff < 2.0) // Within 2 seconds tolerance
    }
}
