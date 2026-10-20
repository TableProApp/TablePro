import Foundation
@testable import TableProMSSQLCore
import Testing

struct MSSQLDatetimeFormatterTests {
    @Test func testDatetimeIsReformatted() {
        let result = MSSQLDatetimeFormatter.reformat("Jan 15 2024 10:30:00:123AM", type: .dateTime)
        #expect(result == "2024-01-15 10:30:00.123")
    }

    @Test func testPMHoursAreAdjusted() {
        let result = MSSQLDatetimeFormatter.reformat("Mar 5 2024 2:45:30PM", type: .dateTime)
        #expect(result == "2024-03-05 14:45:30")
    }

    @Test func testNoonHandledCorrectly() {
        #expect(MSSQLDatetimeFormatter.parse("Jun 1 2024 12:00:00PM") == "2024-06-01 12:00:00")
    }

    @Test func testMidnightHandledCorrectly() {
        #expect(MSSQLDatetimeFormatter.parse("Jun 1 2024 12:00:00AM") == "2024-06-01 00:00:00")
    }

    @Test func testAlreadyISOPassesThrough() {
        let raw = "2024-01-15 10:30:00.123"
        #expect(MSSQLDatetimeFormatter.parse(raw) == raw)
    }

    @Test func testReformatReturnsNilForNonDatetimeType() {
        #expect(MSSQLDatetimeFormatter.reformat("Jan 15 2024 10:30:00AM", type: .int) == nil)
        #expect(MSSQLDatetimeFormatter.reformat("Jan 15 2024 10:30:00AM", type: .nvarchar) == nil)
    }

    @Test func testEmptyInputReturnsNil() {
        #expect(MSSQLDatetimeFormatter.parse("") == nil)
        #expect(MSSQLDatetimeFormatter.parse("   ") == nil)
    }

    @Test func testInvalidMonthReturnsNil() {
        #expect(MSSQLDatetimeFormatter.parse("Xyz 1 2024 10:00AM") == nil)
    }

    @Test func testFractionalSecondsPreserved() {
        let result = MSSQLDatetimeFormatter.parse("Jan 1 2024 1:00:00:1234567AM")
        #expect(result == "2024-01-01 01:00:00.1234567")
    }

    @Test func testDate2025Handled() {
        #expect(MSSQLDatetimeFormatter.reformat("Dec 31 2025 11:59:59:999PM", type: .dateTime2) == "2025-12-31 23:59:59.999")
    }

    // Measured on SQL Server 2022: dbconvert writes a time(7) 23:59:59.9999999 as 1900-01-01 23:59:59.9999999.
    @Test("A time reads as the time of day, without the date db-lib converts it on")
    func timeDropsTheBaseDate() {
        #expect(MSSQLDatetimeFormatter.reformat("1900-01-01 23:59:59.9999999", type: .time) == "23:59:59.9999999")
        #expect(MSSQLDatetimeFormatter.reformat("Jan  1 1900 12:00:00:0000000AM", type: .time) == "00:00:00.0000000")
        #expect(MSSQLDatetimeFormatter.reformat("1900-01-01 08:00:00", type: .dateTime) == "1900-01-01 08:00:00")
    }

    // Measured on SQL Server 2022: dbconvert writes the date 0001-01-01 as Jan  1 0001 12:00:00:0000000AM.
    @Test("A date reads as the date alone, without the midnight db-lib adds")
    func dateDropsTheTime() {
        #expect(MSSQLDatetimeFormatter.reformat("Jan  1 0001 12:00:00:0000000AM", type: .date) == "0001-01-01")
        #expect(MSSQLDatetimeFormatter.reformat("9999-12-31 00:00:00", type: .date) == "9999-12-31")
    }

    @Test func testDateTimeOffsetKeepsAPositiveOffset() {
        #expect(MSSQLDatetimeFormatter.dateTimeOffset("Jan  2 2024  3:04:05:1234567AM", offsetMinutes: 330) == "2024-01-02T03:04:05.1234567+05:30")
    }

    @Test func testDateTimeOffsetKeepsANegativeOffset() {
        #expect(MSSQLDatetimeFormatter.dateTimeOffset("Jan  2 2024  3:04:05:PM", offsetMinutes: -480) == "2024-01-02T15:04:05-08:00")
    }

    @Test func testDateTimeOffsetAtUTCSaysSo() {
        #expect(MSSQLDatetimeFormatter.dateTimeOffset("Jan 15 2024 10:30:45:1234567AM", offsetMinutes: 0) == "2024-01-15T10:30:45.1234567+00:00")
    }

    @Test func testDateTimeOffsetKeepsAnOffsetWithMinutesBehindUTC() {
        #expect(MSSQLDatetimeFormatter.dateTimeOffset("Jan 15 2024 10:30:45AM", offsetMinutes: -210) == "2024-01-15T10:30:45-03:30")
    }

    @Test func testDateTimeOffsetOfUnreadableTextIsNil() {
        #expect(MSSQLDatetimeFormatter.dateTimeOffset("not a date", offsetMinutes: 60) == nil)
    }
}
