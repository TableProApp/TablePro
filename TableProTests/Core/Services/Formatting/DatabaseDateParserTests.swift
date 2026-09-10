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
        let parsed = try #require(DatabaseDateParser.parse("2024-9-1"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = parsed.timeZone

        #expect(calendar.component(.year, from: parsed.date) == 2_024)
        #expect(calendar.component(.month, from: parsed.date) == 9)
        #expect(calendar.component(.day, from: parsed.date) == 1)
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

    /// A value with no offset names a wall clock, and GMT is the zone that always has the one it
    /// names. The answer is the same whatever zone the reader's Mac is in, which is the property
    /// worth guarding: it used to depend on the host.
    @Test("A value with no offset keeps its wall clock")
    func naiveValuesKeepTheirWallClock() throws {
        let parsed = try #require(DatabaseDateParser.parse("2024-03-01 12:00:00"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = parsed.timeZone

        #expect(parsed.timeZone.secondsFromGMT() == 0)
        #expect(calendar.component(.hour, from: parsed.date) == 12)
        #expect(calendar.component(.day, from: parsed.date) == 1)
    }

    /// 02:30 did not exist in New York on 10 March 2024, so reading the value in the reader's zone
    /// moved it to 03:30 on screen and an edit to the date alone then wrote 03:30 back over the
    /// stored time.
    @Test("A wall clock inside a daylight-saving gap is kept as written")
    func daylightSavingGapValueIsKept() throws {
        let text = "2024-03-10 02:30:00"
        let parsed = try #require(DatabaseDateParser.parse(text))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = parsed.timeZone

        #expect(calendar.component(.hour, from: parsed.date) == 2)
        #expect(calendar.component(.minute, from: parsed.date) == 30)
        #expect(DateEditingService.string(from: parsed.date, like: parsed) == text)
    }

    /// Samoa skipped 30 December 2011 to cross the date line, so a value stored on that day failed
    /// to parse in a reader's zone and rendered as raw text with no picker.
    @Test("A day some zone skipped is still a date")
    func aDaySomeZoneSkippedStillParses() throws {
        for text in ["2011-12-30", "2011-12-30 12:00:00"] {
            let parsed = try #require(DatabaseDateParser.parse(text), "\(text) should parse")
            #expect(DateEditingService.string(from: parsed.date, like: parsed) == text)
        }
    }

    /// Swift Charts labels a date axis in the reader's zone, so a naive value is handed the instant
    /// whose reader-zone wall clock is the text the grid prints. A value with its own offset names a
    /// real instant and is plotted as it is.
    @Test("The chart plots a naive value at the wall clock the grid shows")
    func plottableDateFollowsTheReadersZone() throws {
        let naive = try #require(DatabaseDateParser.parse("2024-06-15 12:00:00"))
        var reader = Calendar(identifier: .gregorian)
        reader.timeZone = .current

        #expect(reader.component(.hour, from: naive.plottableDate) == 12)
        #expect(reader.component(.day, from: naive.plottableDate) == 15)

        let zoned = try #require(DatabaseDateParser.parse("2024-06-15 12:00:00+07"))
        #expect(zoned.plottableDate == zoned.date)
    }

    /// A `Z` suffix resolves to GMT and so does a value with no suffix, so the zone alone cannot
    /// tell a UTC value from a naive one.
    @Test("Only the suffix says whether the database supplied a zone")
    func carriesItsOwnZoneReadsTheSuffix() throws {
        #expect(try #require(DatabaseDateParser.parse("2024-06-15 12:00:00Z")).carriesItsOwnZone)
        #expect(try #require(DatabaseDateParser.parse("2024-06-15 12:00:00")).carriesItsOwnZone == false)
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

    /// Measured against PostgreSQL 17: the server widens the offset to whatever the zone needs and
    /// never writes `Z`, so `2024-12-31 23:59:59+00` and `+05:45` are both ordinary output. The grid
    /// prints this text back, so each spelling has to survive the parse intact.
    @Test("Every offset spelling PostgreSQL writes is captured verbatim")
    func offsetSpellingsSurvive() throws {
        let spellings = ["+07", "+00", "-03:30", "+05:45", "Z", "+0700"]
        for spelling in spellings {
            let parsed = try #require(DatabaseDateParser.parse("2024-12-31 23:59:59\(spelling)"))
            #expect(parsed.layout.timeZoneSuffix == spelling)
        }
    }

    /// `Date` is a `Double` of seconds and cannot hold the digits, so the whole second is carried
    /// separately and the digits stay in the layout. Display reads both.
    @Test("Sub-second digits are kept beside the instant, not inside it")
    func fractionalSecondsAreKeptVerbatim() throws {
        for fraction in [".5", ".123456", ".789012", ".000000001", ".999999999", ".9999999999"] {
            let parsed = try #require(DatabaseDateParser.parse("2024-03-15 09:30:00\(fraction)Z"))
            #expect(parsed.layout.fractionalSeconds == fraction)

            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
            let seconds = calendar.dateComponents([.second, .nanosecond], from: parsed.wholeSecond)
            #expect(seconds.second == 0, "\(fraction) rolled the second to \(seconds.second ?? -1)")
            #expect(seconds.nanosecond == 0)
        }
    }

    /// A fraction near one second rounds the `Double` up, which rolled the day and made the value
    /// refuse to parse at all.
    @Test("A fraction longer than nanosecond precision still parses")
    func overlongFractionStillParses() throws {
        let parsed = try #require(DatabaseDateParser.parse("2024-02-29 23:59:59.9999999999"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = parsed.timeZone
        let day = calendar.dateComponents([.month, .day], from: parsed.wholeSecond)

        #expect(day.month == 2)
        #expect(day.day == 29)
    }

    @Test("A value with no offset reports none rather than the reader's own")
    func naiveValueCarriesNoSuffix() throws {
        let parsed = try #require(DatabaseDateParser.parse("2024-12-31 23:59:59"))

        #expect(parsed.layout.timeZoneSuffix == nil)
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
