@testable import TableProMSSQLCore
import XCTest

final class MSSQLDatetimeFormatterTests: XCTestCase {
    func testDatetimeIsReformatted() {
        let result = MSSQLDatetimeFormatter.reformat("Jan 15 2024 10:30:00:123AM", type: .dateTime)
        XCTAssertEqual(result, "2024-01-15 10:30:00.123")
    }

    func testPMHoursAreAdjusted() {
        let result = MSSQLDatetimeFormatter.reformat("Mar 5 2024 2:45:30PM", type: .dateTime)
        XCTAssertEqual(result, "2024-03-05 14:45:30")
    }

    func testNoonHandledCorrectly() {
        XCTAssertEqual(MSSQLDatetimeFormatter.parse("Jun 1 2024 12:00:00PM"), "2024-06-01 12:00:00")
    }

    func testMidnightHandledCorrectly() {
        XCTAssertEqual(MSSQLDatetimeFormatter.parse("Jun 1 2024 12:00:00AM"), "2024-06-01 00:00:00")
    }

    func testAlreadyISOPassesThrough() {
        let raw = "2024-01-15 10:30:00.123"
        XCTAssertEqual(MSSQLDatetimeFormatter.parse(raw), raw)
    }

    func testReformatReturnsNilForNonDatetimeType() {
        XCTAssertNil(MSSQLDatetimeFormatter.reformat("Jan 15 2024 10:30:00AM", type: .int))
        XCTAssertNil(MSSQLDatetimeFormatter.reformat("Jan 15 2024 10:30:00AM", type: .nvarchar))
    }

    func testEmptyInputReturnsNil() {
        XCTAssertNil(MSSQLDatetimeFormatter.parse(""))
        XCTAssertNil(MSSQLDatetimeFormatter.parse("   "))
    }

    func testInvalidMonthReturnsNil() {
        XCTAssertNil(MSSQLDatetimeFormatter.parse("Xyz 1 2024 10:00AM"))
    }

    func testFractionalSecondsPreserved() {
        let result = MSSQLDatetimeFormatter.parse("Jan 1 2024 1:00:00:1234567AM")
        XCTAssertEqual(result, "2024-01-01 01:00:00.1234567")
    }

    func testDate2025Handled() {
        XCTAssertEqual(MSSQLDatetimeFormatter.reformat("Dec 31 2025 11:59:59:999PM", type: .dateTime2),
                       "2025-12-31 23:59:59.999")
    }

    func testDateTimeOffsetKeepsAPositiveOffset() {
        XCTAssertEqual(
            MSSQLDatetimeFormatter.dateTimeOffset("Jan  2 2024  3:04:05:1234567AM", offsetMinutes: 330),
            "2024-01-02T03:04:05.1234567+05:30"
        )
    }

    func testDateTimeOffsetKeepsANegativeOffset() {
        XCTAssertEqual(
            MSSQLDatetimeFormatter.dateTimeOffset("Jan  2 2024  3:04:05:PM", offsetMinutes: -480),
            "2024-01-02T15:04:05-08:00"
        )
    }

    func testDateTimeOffsetAtUTCSaysSo() {
        XCTAssertEqual(
            MSSQLDatetimeFormatter.dateTimeOffset("Jan 15 2024 10:30:45:1234567AM", offsetMinutes: 0),
            "2024-01-15T10:30:45.1234567+00:00"
        )
    }

    func testDateTimeOffsetKeepsAnOffsetWithMinutesBehindUTC() {
        XCTAssertEqual(
            MSSQLDatetimeFormatter.dateTimeOffset("Jan 15 2024 10:30:45AM", offsetMinutes: -210),
            "2024-01-15T10:30:45-03:30"
        )
    }

    func testDateTimeOffsetOfUnreadableTextIsNil() {
        XCTAssertNil(MSSQLDatetimeFormatter.dateTimeOffset("not a date", offsetMinutes: 60))
    }
}
