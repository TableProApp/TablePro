//
//  DateExtensionsTests.swift
//  TableProTests
//
//  Tests for Date extension methods
//

import Foundation
import Testing

@testable import TablePro

@Suite("Date Extensions")
struct DateExtensionsTests {
    @Test("Recent date returns relative string")
    func testRecentDate() {
        let date = Date().addingTimeInterval(-30)
        let result = date.timeAgoDisplay()
        // RelativeDateTimeFormatter handles "just now" / "seconds ago" depending on locale
        #expect(!result.isEmpty)
    }

    @Test("1 minute ago")
    func testOneMinuteAgo() {
        let date = Date().addingTimeInterval(-60)
        let result = date.timeAgoDisplay()
        #expect(result.contains("1") && result.contains("minute"))
    }

    @Test("Multiple minutes ago")
    func testMultipleMinutesAgo() {
        let date = Date().addingTimeInterval(-30 * 60)
        let result = date.timeAgoDisplay()
        #expect(result.contains("30") && result.contains("minute"))
    }

    @Test("1 hour ago")
    func testOneHourAgo() {
        let date = Date().addingTimeInterval(-3_600)
        let result = date.timeAgoDisplay()
        #expect(result.contains("1") && result.contains("hour"))
    }

    @Test("Multiple hours ago")
    func testMultipleHoursAgo() {
        let date = Date().addingTimeInterval(-5 * 3_600)
        let result = date.timeAgoDisplay()
        #expect(result.contains("5") && result.contains("hour"))
    }

    @Test("1 day ago")
    func testOneDayAgo() {
        let date = Date().addingTimeInterval(-86_400)
        let result = date.timeAgoDisplay()
        #expect(result.contains("1") && result.contains("day"))
    }

    @Test("Multiple days ago")
    func testMultipleDaysAgo() {
        let date = Date().addingTimeInterval(-3 * 86_400)
        let result = date.timeAgoDisplay()
        #expect(result.contains("3") && result.contains("day"))
    }

    @Test("1 week ago")
    func testOneWeekAgo() {
        let date = Date().addingTimeInterval(-7 * 86_400)
        let result = date.timeAgoDisplay()
        #expect(result.contains("1") && result.contains("week"))
    }

    @Test("1 month ago")
    func testOneMonthAgo() {
        let date = Date().addingTimeInterval(-35 * 86_400)
        let result = date.timeAgoDisplay()
        #expect(result.contains("1") && result.contains("month"))
    }

    @Test("1 year ago")
    func testOneYearAgo() {
        let date = Date().addingTimeInterval(-400 * 86_400)
        let result = date.timeAgoDisplay()
        #expect(result.contains("1") && result.contains("year"))
    }
}
