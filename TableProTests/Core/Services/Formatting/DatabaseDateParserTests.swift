//
//  DatabaseDateParserTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("DatabaseDateParser")
struct DatabaseDateParserTests {
    /// Every spelling TablePro's drivers put on the wire. Display, the chart's time axis and the
    /// cell editor all read this one list, which is what stops a second grammar drifting from it.
    static let wireSpellings = [
        "2024-03-01 12:00:00",
        "2024-03-01T12:00:00",
        "2024-03-01T12:00:00Z",
        "2024-03-01T12:00:00+0700",
        "2024-03-01T12:00:00+07:00",
        "2024-03-01T12:00:00.123Z",
        "2024-03-01 12:00:00+07",
        "2024-03-01 12:00:00+07:00",
        "2024-03-01 12:00:00.123456",
        "2024-03-01 12:00:00.123456+07",
        "2024-03-01 12:00:00.5",
        "2024-03-01",
        "12:00:00",
        "12:00:00+07",
        "12:00:00.5",
    ]

    @Test("Reads the spellings MySQL, PostgreSQL, SQLite and SQL Server put on the wire")
    func readsEveryWireSpelling() {
        for spelling in Self.wireSpellings {
            #expect(DatabaseDateParser.date(from: spelling) != nil, "\(spelling) should parse")
        }
    }

    @Test("An unpadded month or day still reads as a date")
    func unpaddedComponentsParse() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let parsed = try #require(DatabaseDateParser.date(from: "2024-9-1"))

        #expect(calendar.component(.year, from: parsed) == 2_024)
        #expect(calendar.component(.month, from: parsed) == 9)
        #expect(calendar.component(.day, from: parsed) == 1)
    }

    @Test("A time with an offset reads as a date, the way the same value does with a date in front")
    func timeWithOffsetIsReadable() throws {
        let parsed = try #require(DatabaseDateParser.parse("12:00:00+07"))

        #expect(parsed.layout.hasDate == false)
        #expect(parsed.layout.hasTime)
        #expect(parsed.timeZone.secondsFromGMT() == 25_200)
    }

    @Test("A space-separated offset is read as the instant it names, like the ISO spelling")
    func spaceSeparatedOffsetMatchesIsoSpelling() throws {
        let iso = try #require(DatabaseDateParser.date(from: "2024-03-01T12:00:00+07:00"))
        let spaced = try #require(DatabaseDateParser.date(from: "2024-03-01 12:00:00+07:00"))
        let shortOffset = try #require(DatabaseDateParser.date(from: "2024-03-01 12:00:00+07"))

        #expect(iso == spaced)
        #expect(iso == shortOffset)
    }

    @Test("A value with no offset is read in the reader's own time zone")
    func naiveValuesStayLocal() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let parsed = try #require(DatabaseDateParser.date(from: "2024-03-01 12:00:00"))

        #expect(calendar.component(.hour, from: parsed) == 12)
        #expect(calendar.component(.day, from: parsed) == 1)
    }

    @Test("Sub-second precision reaches the date, so a chart can separate points inside one second")
    func fractionalSecondsReachTheDate() throws {
        let earlier = try #require(DatabaseDateParser.date(from: "2024-03-01 12:00:00.100000"))
        let later = try #require(DatabaseDateParser.date(from: "2024-03-01 12:00:00.900000"))

        #expect(later > earlier)
        #expect((later.timeIntervalSince(earlier) - 0.8).magnitude < 0.001)
    }

    @Test("The spelling is reported alongside the instant, so an edit writes back unchanged")
    func layoutDescribesTheSpelling() throws {
        let parsed = try #require(DatabaseDateParser.parse("2024-03-01T12:00:00.123456+07:00"))

        #expect(parsed.layout.hasDate)
        #expect(parsed.layout.hasTime)
        #expect(parsed.layout.dateTimeSeparator == "T")
        #expect(parsed.layout.fractionalSeconds == ".123456")
        #expect(parsed.layout.timeZoneSuffix == "+07:00")
    }

    @Test("Text that is not a date stays unparsed rather than becoming a plausible one")
    func rejectsNonDates() {
        #expect(DatabaseDateParser.date(from: "not a date") == nil)
        #expect(DatabaseDateParser.date(from: "") == nil)
        #expect(DatabaseDateParser.date(from: "   ") == nil)
        #expect(DatabaseDateParser.date(from: "2024-03-01 12:00:00 trailing") == nil)
        #expect(DatabaseDateParser.date(from: "42") == nil)
        #expect(DatabaseDateParser.date(from: "2024") == nil)
        #expect(DatabaseDateParser.date(from: "Z") == nil)
    }

    @Test("A value outside the calendar is left as text rather than rolled into a plausible date")
    func rejectsOutOfRangeComponents() {
        #expect(DatabaseDateParser.date(from: "0000-00-00 00:00:00") == nil)
        #expect(DatabaseDateParser.date(from: "0000-00-00") == nil)
        #expect(DatabaseDateParser.date(from: "2024-00-10") == nil)
        #expect(DatabaseDateParser.date(from: "2024-13-45") == nil)
        #expect(DatabaseDateParser.date(from: "2024-02-30") == nil)
        #expect(DatabaseDateParser.date(from: "2024-03-01 25:00:00") == nil)
        #expect(DatabaseDateParser.date(from: "2024-03-01 12:60:00") == nil)
    }

    @Test("Alternating spellings all parse, with no state carried between reads")
    func alternatingSpellingsBothParse() {
        for _ in 0 ..< 3 {
            #expect(DatabaseDateParser.date(from: "2024-03-01 12:00:00") != nil)
            #expect(DatabaseDateParser.date(from: "2024-03-01") != nil)
            #expect(DatabaseDateParser.date(from: "2024-03-01T12:00:00Z") != nil)
        }
    }

    @Test("Every spelling the grid can display is also one the editor can write back unchanged")
    func oneGrammarServesDisplayAndEditing() throws {
        for spelling in Self.wireSpellings {
            let parsed = try #require(DatabaseDateParser.parse(spelling), "\(spelling) should parse")
            let written = DateEditingService.string(from: parsed.date, like: parsed)
            #expect(written == spelling, "\(spelling) should write back unchanged, got \(written)")
        }
    }
}
