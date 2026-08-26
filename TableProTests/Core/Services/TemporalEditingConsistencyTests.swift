//
//  TemporalEditingConsistencyTests.swift
//  TableProTests
//
//  The grid, the cell editor and the write-back have to agree about a temporal value: which instant
//  it names, which zone it is read in, and which fields it spells.
//

import Foundation
import Testing

@testable import TablePro

@Suite("Temporal Editing Consistency")
struct TemporalEditingConsistencyTests {
    // MARK: - The editor's fields decide what is written

    /// A `DATETIME` column holding date-only text showed hour, minute and second steppers, but the
    /// write-back copied the old text's shape and dropped the time. The result equalled the stored
    /// value, so the commit was discarded with no error and no dirty marker.
    @Test("A time entered into a date-only value is written, not dropped")
    func testEnteredTimeSurvives() throws {
        let parsed = try #require(DatabaseDateParser.parse("2024-03-15"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = parsed.timeZone
        let picked = try #require(
            calendar.date(from: DateComponents(year: 2024, month: 3, day: 15, hour: 14, minute: 30, second: 0))
        )

        let written = DateEditingService.string(from: picked, like: parsed, offered: .dateAndTime)
        #expect(written == "2024-03-15 14:30:00")
        #expect(written != "2024-03-15")
    }

    @Test("Without an offered set the value keeps the shape it arrived in")
    func testLayoutStillDrivesTheDefault() throws {
        let parsed = try #require(DatabaseDateParser.parse("2024-03-15"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = parsed.timeZone
        let picked = try #require(
            calendar.date(from: DateComponents(year: 2024, month: 3, day: 15, hour: 14, minute: 30, second: 0))
        )
        #expect(DateEditingService.string(from: picked, like: parsed) == "2024-03-15")
    }

    @Test("A date-only editor on a value carrying time keeps the time")
    func testDateOnlyEditorDoesNotTruncate() throws {
        let parsed = try #require(DatabaseDateParser.parse("2024-03-15 09:00:00"))
        let written = DateEditingService.string(from: parsed.date, like: parsed, offered: .dateOnly)
        #expect(written == "2024-03-15 09:00:00")
    }

    @Test("An offset suffix survives the write-back")
    func testOffsetSuffixPreserved() throws {
        let parsed = try #require(DatabaseDateParser.parse("2024-03-15 01:00:00+05:30"))
        let written = DateEditingService.string(from: parsed.date, like: parsed, offered: .dateAndTime)
        #expect(written == "2024-03-15 01:00:00+05:30")
    }

    // MARK: - The grid reads a value in the zone the editor opens it in

    /// The grid formatted every value in the reader's zone while the picker opened it in the value's
    /// own, so one cell showed 14 March in the grid and 15 March in the calendar.
    @Test("An offset-bearing value formats in its own zone")
    @MainActor
    func testGridUsesTheValuesOwnZone() throws {
        let service = DateFormattingService.shared
        service.updateFormat(.iso8601)

        let text = "2024-03-15 01:00:00+05:30"
        let formatted = try #require(service.format(dateString: text, columnType: .timestamp(rawType: "TIMESTAMPTZ")))
        let parsed = try #require(DatabaseDateParser.parse(text))

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = parsed.timeZone
        let day = calendar.component(.day, from: parsed.date)

        #expect(day == 15)
        #expect(formatted.contains("2024-03-15"))
    }

    @Test("A naive value still reads in the reader's own zone")
    @MainActor
    func testNaiveValueUnchanged() throws {
        let service = DateFormattingService.shared
        service.updateFormat(.iso8601)
        let formatted = try #require(
            service.format(dateString: "2024-06-01 09:30:00", columnType: .timestamp(rawType: "DATETIME"))
        )
        #expect(formatted.contains("2024-06-01"))
        #expect(formatted.contains("09:30"))
    }

    @Test("Formatting one value does not change how the next one reads")
    @MainActor
    func testFormatterZoneDoesNotLeak() throws {
        let service = DateFormattingService.shared
        service.updateFormat(.iso8601)
        let offsetType = ColumnType.timestamp(rawType: "TIMESTAMPTZ")

        _ = service.format(dateString: "2024-03-15 01:00:00+05:30", columnType: offsetType)
        let naive = try #require(service.format(dateString: "2024-06-01 09:30:00", columnType: offsetType))
        #expect(naive.contains("09:30"))
    }
}
