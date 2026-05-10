//
//  MSSQLDatetimeFormatterTests.swift
//  TableProTests
//
//  Pins the FreeTDS msdblib → ISO 8601 datetime conversion.
//  Covers all formats observed from FreeTDS dbconvert(... SYBCHAR) output:
//  legacy DATETIME (3-digit fractional), DATETIME2 (7-digit fractional),
//  SMALLDATETIME (no seconds), already-ISO passthrough, and AM/PM boundary cases.
//

import Foundation
@testable import MSSQLDriver
import Testing

@Suite("MSSQLDatetimeFormatter")
struct MSSQLDatetimeFormatterTests {
    // MARK: - Legacy AM/PM format from FreeTDS msdblib

    @Test("DATETIME2 with 7-digit fractional reformats to ISO with all digits preserved")
    func datetime2SevenDigitFractional() {
        let result = MSSQLDatetimeFormatter.parse("May 10 2026  7:58:53:2960999AM")
        #expect(result == "2026-05-10 07:58:53.2960999")
    }

    @Test("DATETIME with 3-digit fractional reformats to ISO with milliseconds preserved")
    func datetimeThreeDigitFractional() {
        let result = MSSQLDatetimeFormatter.parse("Jan  5 2024 11:30:00:123PM")
        #expect(result == "2024-01-05 23:30:00.123")
    }

    @Test("SMALLDATETIME without seconds defaults seconds to 00")
    func smallDatetimeNoSeconds() {
        let result = MSSQLDatetimeFormatter.parse("Mar 15 2025  3:45PM")
        #expect(result == "2025-03-15 15:45:00")
    }

    @Test("DATETIME without fractional yields ISO without fractional suffix")
    func datetimeNoFractional() {
        let result = MSSQLDatetimeFormatter.parse("Dec  1 2023  9:00:00AM")
        #expect(result == "2023-12-01 09:00:00")
    }

    // MARK: - AM/PM boundary cases

    @Test("12 AM converts to 00 (midnight)")
    func twelveAMisMidnight() {
        let result = MSSQLDatetimeFormatter.parse("Jun  1 2025 12:30:00AM")
        #expect(result == "2025-06-01 00:30:00")
    }

    @Test("12 PM stays at 12 (noon)")
    func twelvePMisNoon() {
        let result = MSSQLDatetimeFormatter.parse("Jun  1 2025 12:30:00PM")
        #expect(result == "2025-06-01 12:30:00")
    }

    @Test("1 AM stays at 01")
    func oneAMisOne() {
        let result = MSSQLDatetimeFormatter.parse("Jun  1 2025  1:00:00AM")
        #expect(result == "2025-06-01 01:00:00")
    }

    @Test("11 PM converts to 23")
    func elevenPMisTwentyThree() {
        let result = MSSQLDatetimeFormatter.parse("Jun  1 2025 11:00:00PM")
        #expect(result == "2025-06-01 23:00:00")
    }

    // MARK: - Validation rejects malformed input

    @Test("Hour 13 with AM marker is rejected (12-hour values must be 1...12)")
    func thirteenAMrejected() {
        let result = MSSQLDatetimeFormatter.parse("Jun  1 2025 13:00:00AM")
        #expect(result == nil)
    }

    @Test("Hour 0 with AM marker is rejected (12-hour values must be 1...12)")
    func zeroAMrejected() {
        let result = MSSQLDatetimeFormatter.parse("Jun  1 2025  0:00:00AM")
        #expect(result == nil)
    }

    @Test("Unknown month abbreviation is rejected")
    func unknownMonthRejected() {
        let result = MSSQLDatetimeFormatter.parse("Foo  1 2025 12:00:00PM")
        #expect(result == nil)
    }

    @Test("Day 32 is rejected")
    func dayOutOfRangeRejected() {
        let result = MSSQLDatetimeFormatter.parse("Jan 32 2025 12:00:00PM")
        #expect(result == nil)
    }

    @Test("Year 0 is rejected")
    func yearZeroRejected() {
        let result = MSSQLDatetimeFormatter.parse("Jan  1 0 12:00:00PM")
        #expect(result == nil)
    }

    @Test("Year 10000 is rejected (out of ISO 8601 range)")
    func yearTooLargeRejected() {
        let result = MSSQLDatetimeFormatter.parse("Jan  1 10000 12:00:00PM")
        #expect(result == nil)
    }

    @Test("Minute 60 is rejected")
    func minuteOutOfRangeRejected() {
        let result = MSSQLDatetimeFormatter.parse("Jan  1 2025 12:60:00PM")
        #expect(result == nil)
    }

    @Test("Empty string returns nil")
    func emptyStringRejected() {
        let result = MSSQLDatetimeFormatter.parse("")
        #expect(result == nil)
    }

    @Test("Whitespace-only string returns nil")
    func whitespaceRejected() {
        let result = MSSQLDatetimeFormatter.parse("   ")
        #expect(result == nil)
    }

    // MARK: - ISO passthrough

    @Test("Already-ISO date passes through unchanged")
    func isoDatePassthrough() {
        let result = MSSQLDatetimeFormatter.parse("2026-05-10")
        #expect(result == "2026-05-10")
    }

    @Test("Already-ISO datetime passes through unchanged")
    func isoDatetimePassthrough() {
        let result = MSSQLDatetimeFormatter.parse("2026-05-10 14:30:00")
        #expect(result == "2026-05-10 14:30:00")
    }

    @Test("ISO datetime with fractional passes through unchanged")
    func isoDatetimeWithFractionalPassthrough() {
        let result = MSSQLDatetimeFormatter.parse("2026-05-10 14:30:00.1234567")
        #expect(result == "2026-05-10 14:30:00.1234567")
    }

    // MARK: - 24-hour input without AM/PM marker

    @Test("24-hour input without AM/PM accepts hour 23")
    func twentyFourHourAccepted() {
        let result = MSSQLDatetimeFormatter.parse("Jun  1 2025 23:30:00")
        #expect(result == "2025-06-01 23:30:00")
    }

    @Test("24-hour input rejects hour 24")
    func twentyFourHourRejectsTwentyFour() {
        let result = MSSQLDatetimeFormatter.parse("Jun  1 2025 24:00:00")
        #expect(result == nil)
    }

    // MARK: - reformat() type dispatch

    @Test("reformat returns nil for non-datetime types")
    func reformatRejectsNonDatetimeTypes() {
        // SYBINT4 = 56
        #expect(MSSQLDatetimeFormatter.reformat("Jan  1 2025 12:00:00PM", srcType: 56) == nil)
    }

    @Test("reformat returns ISO for legacy DATETIME type (SYBDATETIME=61)")
    func reformatDatetimeType() {
        #expect(MSSQLDatetimeFormatter.reformat("Jan  1 2025 12:00:00PM", srcType: 61) == "2025-01-01 12:00:00")
    }

    @Test("reformat returns ISO for SMALLDATETIME type (SYBDATETIME4=58)")
    func reformatSmallDatetimeType() {
        #expect(MSSQLDatetimeFormatter.reformat("Mar 15 2025  3:45PM", srcType: 58) == "2025-03-15 15:45:00")
    }

    @Test("reformat returns ISO for nullable DATETIME (SYBDATETIMN=111)")
    func reformatNullableDatetimeType() {
        #expect(MSSQLDatetimeFormatter.reformat("Jan  1 2025 12:00:00PM", srcType: 111) == "2025-01-01 12:00:00")
    }

    @Test("reformat returns ISO for SYBMSDATETIME2 (raw constant 42)")
    func reformatMSDatetime2Type() {
        let result = MSSQLDatetimeFormatter.reformat("May 10 2026  7:58:53:2960999AM", srcType: 42)
        #expect(result == "2026-05-10 07:58:53.2960999")
    }

    @Test("reformat returns nil for unverified DATETIMEOFFSET (raw constant 43)")
    func reformatDatetimeOffsetExcluded() {
        // SYBMSDATETIMEOFFSET (43) is intentionally not handled until the offset
        // suffix format is verified end-to-end.
        let result = MSSQLDatetimeFormatter.reformat("May 10 2026  7:58:53:2960999 +05:30AM", srcType: 43)
        #expect(result == nil)
    }
}
