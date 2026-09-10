//
//  DateFormattingServiceTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("DateFormattingService column-type buckets")
@MainActor
struct DateFormattingServiceTests {
    @Test("DATE column with datetime wire value formats to date only")
    func dateColumnStripsTime() {
        DateFormattingService.shared.updateFormat(.iso8601)
        let result = DateFormattingService.shared.format(
            dateString: "2024-03-01 12:34:56",
            columnType: .date(rawType: "DATE")
        )
        #expect(result == "2024-03-01")
    }

    @Test("DATETIME column keeps date and time")
    func datetimeColumnKeepsBothComponents() {
        DateFormattingService.shared.updateFormat(.iso8601)
        let result = DateFormattingService.shared.format(
            dateString: "2024-03-01 12:34:56",
            columnType: .datetime(rawType: "DATETIME")
        )
        #expect(result == "2024-03-01 12:34:56")
    }

    @Test("TIME column emits time only")
    func timeColumnEmitsTimeOnly() {
        DateFormattingService.shared.updateFormat(.iso8601)
        let result = DateFormattingService.shared.format(
            dateString: "2024-03-01 12:34:56",
            columnType: .timestamp(rawType: "TIME")
        )
        #expect(result == "12:34:56")
    }

    @Test("TIMETZ column emits time only")
    func timetzColumnEmitsTimeOnly() {
        DateFormattingService.shared.updateFormat(.iso8601)
        let result = DateFormattingService.shared.format(
            dateString: "2024-03-01 12:34:56",
            columnType: .timestamp(rawType: "TIMETZ")
        )
        #expect(result == "12:34:56")
    }

    @Test("nil columnType falls back to datetime formatter")
    func nilColumnTypeFallsBackToDatetime() {
        DateFormattingService.shared.updateFormat(.iso8601)
        let result = DateFormattingService.shared.format(
            dateString: "2024-03-01 12:34:56",
            columnType: nil
        )
        #expect(result == "2024-03-01 12:34:56")
    }

    @Test("unparseable input returns nil")
    func unparseableReturnsNil() {
        DateFormattingService.shared.updateFormat(.iso8601)
        let result = DateFormattingService.shared.format(
            dateString: "not-a-date",
            columnType: .date(rawType: "DATE")
        )
        #expect(result == nil)
    }

    @Test("same wire value formats differently for DATE vs DATETIME (cache bucket isolation)")
    func cacheBucketIsolation() {
        DateFormattingService.shared.updateFormat(.iso8601)
        let wire = "2024-03-01 09:00:00"
        let asDatetime = DateFormattingService.shared.format(
            dateString: wire,
            columnType: .datetime(rawType: "DATETIME")
        )
        let asDate = DateFormattingService.shared.format(
            dateString: wire,
            columnType: .date(rawType: "DATE")
        )
        #expect(asDatetime == "2024-03-01 09:00:00")
        #expect(asDate == "2024-03-01")
    }
}

/// A wall clock alone does not name an instant, so the offset the database sent is printed with it.
/// The offset is the literal text off the value, never a pattern token: a token prints the
/// formatter's zone, which for a value carrying none is the reader's own. (#2702)
@Suite("DateFormattingService time zone display")
@MainActor
struct DateFormattingServiceTimeZoneTests {
    @Test("An offset-bearing timestamp keeps its offset")
    func offsetIsShown() {
        DateFormattingService.shared.updateFormat(.iso8601)
        let result = DateFormattingService.shared.format(
            dateString: "2024-12-31 23:59:59+07",
            columnType: .timestamp(rawType: "TIMESTAMPTZ")
        )
        #expect(result == "2024-12-31 23:59:59+07")
    }

    /// Every spelling measured coming out of PostgreSQL 17, plus the `Z` the MongoDB and Cassandra
    /// drivers write. Each is printed as the database wrote it rather than normalised, so the grid
    /// and a `Cmd+C` of the same cell read the same.
    @Test("Every offset spelling reaches the cell unchanged")
    func offsetSpellingsAreVerbatim() {
        DateFormattingService.shared.updateFormat(.iso8601)
        for spelling in ["+00", "-03:30", "+05:45", "Z", "+0700"] {
            let result = DateFormattingService.shared.format(
                dateString: "2024-12-31 23:59:59\(spelling)",
                columnType: .timestamp(rawType: "TIMESTAMPTZ")
            )
            #expect(result == "2024-12-31 23:59:59\(spelling)")
        }
    }

    @Test("A value carrying no offset gains none")
    func naiveValueGainsNoOffset() {
        DateFormattingService.shared.updateFormat(.iso8601)
        let result = DateFormattingService.shared.format(
            dateString: "2024-12-31 23:59:59",
            columnType: .datetime(rawType: "DATETIME")
        )
        #expect(result == "2024-12-31 23:59:59")
    }

    @Test("A TIMETZ column keeps the offset that qualifies its time")
    func timeOnlyColumnKeepsItsOffset() {
        DateFormattingService.shared.updateFormat(.iso8601)
        let result = DateFormattingService.shared.format(
            dateString: "09:30:00+05:30",
            columnType: .timestamp(rawType: "TIMETZ")
        )
        #expect(result == "09:30:00+05:30")
    }

    @Test("A DATE column renders the date alone, because an offset qualifies a time")
    func dateColumnDropsTheOffset() {
        DateFormattingService.shared.updateFormat(.iso8601)
        let result = DateFormattingService.shared.format(
            dateString: "2024-12-31 23:59:59+07",
            columnType: .date(rawType: "DATE")
        )
        #expect(result == "2024-12-31")
    }

    @Test("A date-only format on a timestamp column renders no offset either")
    func dateOnlyFormatDropsTheOffset() {
        DateFormattingService.shared.updateFormat(.iso8601Date)
        defer { DateFormattingService.shared.updateFormat(.iso8601) }

        let result = DateFormattingService.shared.format(
            dateString: "2024-12-31 23:59:59+07",
            columnType: .timestamp(rawType: "TIMESTAMPTZ")
        )
        #expect(result == "2024-12-31")
    }

    @Test("The offset follows a 12-hour pattern too")
    func twelveHourFormatKeepsTheOffset() {
        DateFormattingService.shared.updateFormat(.usLong)
        defer { DateFormattingService.shared.updateFormat(.iso8601) }

        let result = DateFormattingService.shared.format(
            dateString: "2024-12-31 23:59:59+07",
            columnType: .timestamp(rawType: "TIMESTAMPTZ")
        )
        #expect(result == "12/31/2024 11:59:59 PM+07")
    }

    /// The grid opens the cell editor on the raw text, so a value it prints has to be the value the
    /// write-back reproduces. The suffix travels through the layout for both.
    @Test("The printed offset is the one the write-back writes")
    func displayAgreesWithTheWriteBack() throws {
        DateFormattingService.shared.updateFormat(.iso8601)
        let wire = "2024-12-31 23:59:59+05:45"
        let parsed = try #require(DatabaseDateParser.parse(wire))

        let displayed = DateFormattingService.shared.format(
            dateString: wire,
            columnType: .timestamp(rawType: "TIMESTAMPTZ")
        )
        let written = DateEditingService.string(from: parsed.date, like: parsed, offered: .dateAndTime)

        #expect(displayed == wire)
        #expect(written == wire)
    }
}
