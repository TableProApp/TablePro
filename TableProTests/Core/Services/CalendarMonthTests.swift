//
//  CalendarMonthTests.swift
//  TableProTests
//
//  Tests for the date picker's month grid layout: leading blanks, day count,
//  and weekday symbol ordering across first-weekday settings.
//

import Foundation
import Testing

@testable import TablePro

@Suite("Calendar Month")
struct CalendarMonthTests {
    private func calendar(firstWeekday: Int) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.firstWeekday = firstWeekday
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, in calendar: Calendar) throws -> Date {
        try #require(calendar.date(from: DateComponents(year: year, month: month, day: day)))
    }

    @Test("March 2024 starts on Friday: 5 leading blanks with Sunday first")
    func leadingBlanksSundayFirst() throws {
        let sundayFirst = calendar(firstWeekday: 1)
        let month = try #require(CalendarMonth(containing: date(2_024, 3, 1, in: sundayFirst), calendar: sundayFirst))
        #expect(month.leadingBlanks == 5)
        #expect(month.dayCount == 31)
    }

    @Test("March 2024 has 4 leading blanks with Monday first")
    func leadingBlanksMondayFirst() throws {
        let mondayFirst = calendar(firstWeekday: 2)
        let month = try #require(CalendarMonth(containing: date(2_024, 3, 1, in: mondayFirst), calendar: mondayFirst))
        #expect(month.leadingBlanks == 4)
    }

    @Test("February in a leap year has 29 days")
    func februaryLeapYear() throws {
        let gregorian = calendar(firstWeekday: 1)
        let month = try #require(CalendarMonth(containing: date(2_024, 2, 10, in: gregorian), calendar: gregorian))
        #expect(month.dayCount == 29)
    }

    @Test("February in a non-leap year has 28 days")
    func februaryNonLeapYear() throws {
        let gregorian = calendar(firstWeekday: 1)
        let month = try #require(CalendarMonth(containing: date(2_023, 2, 10, in: gregorian), calendar: gregorian))
        #expect(month.dayCount == 28)
    }

    @Test("days array is leading blanks followed by each day of the month")
    func daysArrayShape() throws {
        let gregorian = calendar(firstWeekday: 1)
        let month = try #require(CalendarMonth(containing: date(2_024, 3, 1, in: gregorian), calendar: gregorian))
        #expect(month.days.count == month.leadingBlanks + month.dayCount)
        #expect(month.days.prefix(month.leadingBlanks).allSatisfy { $0 == nil })
        let firstDay = try #require(month.days[month.leadingBlanks])
        #expect(gregorian.component(.day, from: firstDay) == 1)
    }

    @Test("weekday symbols rotate to the calendar's first weekday")
    func weekdaySymbolOrdering() throws {
        let sundayFirst = calendar(firstWeekday: 1)
        let mondayFirst = calendar(firstWeekday: 2)
        let sunday = try #require(CalendarMonth(containing: date(2_024, 3, 1, in: sundayFirst), calendar: sundayFirst))
        let monday = try #require(CalendarMonth(containing: date(2_024, 3, 1, in: mondayFirst), calendar: mondayFirst))
        #expect(sunday.weekdaySymbols.count == 7)
        #expect(sunday.weekdaySymbols.first == sundayFirst.veryShortWeekdaySymbols[0])
        #expect(monday.weekdaySymbols.first == mondayFirst.veryShortWeekdaySymbols[1])
    }
}
