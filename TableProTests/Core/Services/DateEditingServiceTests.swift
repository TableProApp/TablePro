//
//  DateEditingServiceTests.swift
//  TableProTests
//
//  Tests for parsing database date/time strings and writing edited values back
//  in the same shape, preserving fractional seconds and timezone offsets.
//

import Foundation
import Testing

@testable import TablePro

@Suite("Date Editing")
struct DateEditingServiceTests {
    @Test("MySQL datetime round-trips unchanged")
    func mysqlDatetimeRoundTrip() throws {
        let parsed = try #require(DateEditingService.parse("2024-03-15 09:30:00"))
        #expect(DateEditingService.string(from: parsed.date, like: parsed) == "2024-03-15 09:30:00")
    }

    @Test("ISO 8601 T separator is preserved")
    func isoSeparatorPreserved() throws {
        let parsed = try #require(DateEditingService.parse("2024-03-15T09:30:00"))
        #expect(DateEditingService.string(from: parsed.date, like: parsed) == "2024-03-15T09:30:00")
    }

    @Test("UTC Z suffix round-trips")
    func zuluRoundTrip() throws {
        let parsed = try #require(DateEditingService.parse("2024-03-15T09:30:00Z"))
        #expect(parsed.timeZone.secondsFromGMT() == 0)
        #expect(DateEditingService.string(from: parsed.date, like: parsed) == "2024-03-15T09:30:00Z")
    }

    @Test("timezone offset is preserved verbatim")
    func offsetPreserved() throws {
        let parsed = try #require(DateEditingService.parse("2024-03-15T09:30:00+05:30"))
        #expect(parsed.timeZone.secondsFromGMT() == 19_800)
        #expect(DateEditingService.string(from: parsed.date, like: parsed) == "2024-03-15T09:30:00+05:30")
    }

    @Test("two-digit timezone offset is preserved")
    func shortOffsetPreserved() throws {
        let parsed = try #require(DateEditingService.parse("2024-03-15 09:30:00+00"))
        #expect(DateEditingService.string(from: parsed.date, like: parsed) == "2024-03-15 09:30:00+00")
    }

    @Test("fractional seconds are preserved")
    func fractionalSecondsPreserved() throws {
        let parsed = try #require(DateEditingService.parse("2024-03-15 09:30:00.123456"))
        #expect(DateEditingService.string(from: parsed.date, like: parsed) == "2024-03-15 09:30:00.123456")
    }

    @Test("fractional seconds and offset preserved together")
    func fractionAndOffsetPreserved() throws {
        let parsed = try #require(DateEditingService.parse("2024-03-15T09:30:00.123456+05:30"))
        #expect(DateEditingService.string(from: parsed.date, like: parsed) == "2024-03-15T09:30:00.123456+05:30")
    }

    @Test("date-only round-trips without a time component")
    func dateOnlyRoundTrip() throws {
        let parsed = try #require(DateEditingService.parse("2024-03-15"))
        #expect(parsed.layout.hasTime == false)
        #expect(DateEditingService.string(from: parsed.date, like: parsed) == "2024-03-15")
    }

    @Test("time-only round-trips without a date component")
    func timeOnlyRoundTrip() throws {
        let parsed = try #require(DateEditingService.parse("09:30:45"))
        #expect(parsed.layout.hasDate == false)
        #expect(DateEditingService.string(from: parsed.date, like: parsed) == "09:30:45")
    }

    @Test("time-only fractional seconds are preserved")
    func timeOnlyFractionPreserved() throws {
        let parsed = try #require(DateEditingService.parse("09:30:45.5"))
        #expect(DateEditingService.string(from: parsed.date, like: parsed) == "09:30:45.5")
    }

    @Test("advancing the date keeps fractional seconds")
    func editKeepsFraction() throws {
        let parsed = try #require(DateEditingService.parse("2024-03-15 09:30:00.123456"))
        let nextDay = parsed.date.addingTimeInterval(86_400)
        #expect(DateEditingService.string(from: nextDay, like: parsed) == "2024-03-16 09:30:00.123456")
    }

    @Test("editing the time updates hour, minute, and second")
    func editUpdatesTime() throws {
        let original = try #require(DateEditingService.parse("2024-03-15 09:30:45"))
        let edited = try #require(DateEditingService.parse("2024-03-15 10:15:05"))
        #expect(DateEditingService.string(from: edited.date, like: original) == "2024-03-15 10:15:05")
    }

    @Test("null, empty, and whitespace parse to nil")
    func nullParsesToNil() {
        #expect(DateEditingService.parse(nil) == nil)
        #expect(DateEditingService.parse("") == nil)
        #expect(DateEditingService.parse("   ") == nil)
    }

    @Test("unparseable values parse to nil")
    func unparseableParsesToNil() {
        #expect(DateEditingService.parse("not a date") == nil)
        #expect(DateEditingService.parse("2024") == nil)
        #expect(DateEditingService.parse("Z") == nil)
    }

    @Test("default string for a date column emits date only")
    func defaultDateString() throws {
        let parsed = try #require(DateEditingService.parse("2024-03-15 09:30:45"))
        #expect(DateEditingService.defaultString(from: parsed.date, columnType: .date(rawType: "DATE")) == "2024-03-15")
    }

    @Test("default string for a timestamp column emits date and time")
    func defaultTimestampString() throws {
        let parsed = try #require(DateEditingService.parse("2024-03-15 09:30:45"))
        let value = DateEditingService.defaultString(from: parsed.date, columnType: .timestamp(rawType: "TIMESTAMP"))
        #expect(value == "2024-03-15 09:30:45")
    }

    @Test("default string for a time column emits time only")
    func defaultTimeString() throws {
        let parsed = try #require(DateEditingService.parse("2024-03-15 09:30:45"))
        let value = DateEditingService.defaultString(from: parsed.date, columnType: .timestamp(rawType: "TIME"))
        #expect(value == "09:30:45")
    }

    @Test("date column edits date components only")
    func componentsForDate() {
        #expect(DateEditingService.components(for: .date(rawType: "DATE")) == .dateOnly)
    }

    @Test("time column edits time components only")
    func componentsForTime() {
        #expect(DateEditingService.components(for: .timestamp(rawType: "TIME")) == .timeOnly)
    }

    @Test("time column with precision edits time components only")
    func componentsForTimeWithPrecision() {
        #expect(DateEditingService.components(for: .timestamp(rawType: "TIME(6)")) == .timeOnly)
    }

    @Test("timestamp column edits date and time components")
    func componentsForTimestamp() {
        #expect(DateEditingService.components(for: .timestamp(rawType: "TIMESTAMP")) == .dateAndTime)
    }
}
