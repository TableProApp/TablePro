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

    @Test("Two values one microsecond apart do not draw the same text")
    func subSecondPrecisionSurvives() {
        DateFormattingService.shared.updateFormat(.iso8601)
        let earlier = DateFormattingService.shared.format(
            dateString: "2024-03-15 09:30:00.123456",
            columnType: .timestamp(rawType: "TIMESTAMP(6)")
        )
        let later = DateFormattingService.shared.format(
            dateString: "2024-03-15 09:30:00.789012",
            columnType: .timestamp(rawType: "TIMESTAMP(6)")
        )

        #expect(earlier == "2024-03-15 09:30:00.123456")
        #expect(later == "2024-03-15 09:30:00.789012")
    }

    /// MySQL pads a `DATETIME(6)` to its declared precision on every row, so an all-zero fraction
    /// is the column's shape rather than the value's, and printing it would widen every row of such
    /// a column for nothing.
    @Test("A fraction of nothing but zeros is not printed")
    func allZeroFractionIsDropped() {
        DateFormattingService.shared.updateFormat(.iso8601)
        for fraction in [".0", ".000", ".000000"] {
            let result = DateFormattingService.shared.format(
                dateString: "2024-03-15 09:30:00\(fraction)",
                columnType: .timestamp(rawType: "TIMESTAMP(6)")
            )
            #expect(result == "2024-03-15 09:30:00", "\(fraction) should print no fraction")
        }
    }

    /// The Unix Timestamp display format renders an instant through its own formatter, which must
    /// never carry the slot: a control character is invisible on screen and still reaches the
    /// clipboard, Find and the value filter.
    @Test("The instant formatter carries no slot")
    func instantFormatterCarriesNoMarker() {
        let marker = String(DateFormatOption.fractionalSecondsMarker)
        for option in DateFormatOption.allCases {
            DateFormattingService.shared.updateFormat(option)
            let rendered = DateFormattingService.shared.format(Date(timeIntervalSince1970: 1_700_000_000))
            #expect(!rendered.contains(marker), "\(option) rendered \(rendered)")
        }
        DateFormattingService.shared.updateFormat(.iso8601)
    }

    @Test("The digits are the value's own, not a rounding of them")
    func fractionalDigitsAreVerbatim() {
        DateFormattingService.shared.updateFormat(.iso8601)
        for fraction in [".5", ".000001", ".123", ".999999999"] {
            let result = DateFormattingService.shared.format(
                dateString: "2024-03-15 09:30:00\(fraction)",
                columnType: .timestamp(rawType: "TIMESTAMP")
            )
            #expect(result == "2024-03-15 09:30:00\(fraction)")
        }
    }

    /// A fraction qualifies the seconds, so it goes where the seconds end. Appending would put it
    /// after the designator, `11:59:59 PM.123456`.
    @Test("A 12-hour format keeps the fraction with the seconds")
    func twelveHourFormatPlacesTheFractionAtTheSeconds() {
        DateFormattingService.shared.updateFormat(.usLong)
        defer { DateFormattingService.shared.updateFormat(.iso8601) }

        let result = DateFormattingService.shared.format(
            dateString: "2024-03-15 09:30:00.123456+07",
            columnType: .timestamp(rawType: "TIMESTAMPTZ")
        )
        #expect(result == "03/15/2024 09:30:00.123456 AM+07")
    }

    @Test("A TIMETZ column keeps both its fraction and its offset")
    func timeOnlyColumnKeepsBoth() {
        DateFormattingService.shared.updateFormat(.iso8601)
        let result = DateFormattingService.shared.format(
            dateString: "09:30:00.123456+05:30",
            columnType: .timestamp(rawType: "TIMETZ")
        )
        #expect(result == "09:30:00.123456+05:30")
    }

    @Test("A date-only rendering carries no fraction")
    func dateOnlyRenderingDropsTheFraction() {
        DateFormattingService.shared.updateFormat(.iso8601)
        let onDateColumn = DateFormattingService.shared.format(
            dateString: "2024-03-15 09:30:00.123456",
            columnType: .date(rawType: "DATE")
        )
        #expect(onDateColumn == "2024-03-15")

        DateFormattingService.shared.updateFormat(.euShort)
        defer { DateFormattingService.shared.updateFormat(.iso8601) }
        let onShortFormat = DateFormattingService.shared.format(
            dateString: "2024-03-15 09:30:00.123456",
            columnType: .timestamp(rawType: "TIMESTAMP")
        )
        #expect(onShortFormat == "15/03/2024")
    }

    /// The slot is a control character, so a splice that failed to run would be invisible on screen
    /// and would still reach the clipboard, Find and the value filter.
    @Test("The marker never survives into a cell")
    func markerNeverReachesACell() {
        let marker = String(DateFormatOption.fractionalSecondsMarker)
        for option in DateFormatOption.allCases {
            DateFormattingService.shared.updateFormat(option)
            for spelling in DatabaseDateParserTests.wireSpellings {
                for rawType in ["TIMESTAMP", "DATE", "TIMETZ"] {
                    let result = DateFormattingService.shared.format(
                        dateString: spelling,
                        columnType: .timestamp(rawType: rawType)
                    )
                    #expect(result?.contains(marker) != true, "\(option) \(rawType) \(spelling)")
                }
            }
        }
        DateFormattingService.shared.updateFormat(.iso8601)
    }

    /// The marked pattern is derived from the plain one, so the two cannot drift: removing the
    /// quoted slot has to give the pattern back exactly.
    @Test("The marked pattern is the plain pattern plus a slot")
    func markedPatternMatchesThePlainOne() {
        let slot = "'\(DateFormatOption.fractionalSecondsMarker)'"
        for option in DateFormatOption.allCases {
            for components in [TemporalComponents.dateOnly, .timeOnly, .dateAndTime] {
                let plain = option.formatString(for: components)
                guard let marked = option.fractionalSecondsFormatString(for: components) else {
                    #expect(!option.rendersTime(for: components) || !plain.contains("ss"))
                    continue
                }
                #expect(marked.replacingOccurrences(of: slot, with: "") == plain)
                #expect(marked.components(separatedBy: slot).count == 2)
            }
        }
    }

    /// A captured `TimeZone.current` never follows a system time zone change, measured, so the one
    /// formatter that renders an instant holds `.autoupdatingCurrent` instead.
    @Test("An instant renders in the reader's live zone")
    func instantRendersInTheLiveZone() {
        DateFormattingService.shared.updateFormat(.iso8601)
        let instant = Date(timeIntervalSince1970: 1_700_000_000)

        let control = DateFormatter()
        control.locale = Locale(identifier: "en_US_POSIX")
        control.calendar = Calendar(identifier: .gregorian)
        control.timeZone = .autoupdatingCurrent
        control.dateFormat = DateFormatOption.iso8601.formatString(for: .dateAndTime)

        #expect(DateFormattingService.shared.format(instant) == control.string(from: instant))
    }

    /// Its zone is fixed but its pattern is not: a Unix-timestamp column has to follow the user's
    /// chosen date format like every other cell.
    @Test("The instant formatter follows the chosen date format")
    func instantFormatterFollowsTheChosenFormat() {
        let instant = Date(timeIntervalSince1970: 1_700_000_000)
        DateFormattingService.shared.updateFormat(.euLong)
        defer { DateFormattingService.shared.updateFormat(.iso8601) }
        let european = DateFormattingService.shared.format(instant)

        DateFormattingService.shared.updateFormat(.iso8601)
        let iso = DateFormattingService.shared.format(instant)

        #expect(european != iso)
        #expect(european.contains("/"))
        #expect(iso.contains("-"))
    }

    @Test("A system time zone change raises the generation the grid caches on")
    func systemTimeZoneChangeRaisesTheGeneration() async {
        let before = DateFormattingService.shared.systemTimeZoneGeneration
        NotificationCenter.default.post(name: .NSSystemTimeZoneDidChange, object: nil)

        for _ in 0 ..< 100 where DateFormattingService.shared.systemTimeZoneGeneration == before {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(DateFormattingService.shared.systemTimeZoneGeneration > before)
    }

    /// The grid keeps a tab's formatted text while the tab is unmounted, so the generation has to be
    /// part of what the cache was built from or nothing replaces it.
    @Test("The display identity moves with the generation")
    func displayIdentityMovesWithTheGeneration() {
        func identity(generation: Int) -> DataGridDisplayIdentity {
            DataGridDisplayIdentity(
                bufferEpoch: 1,
                resultSetId: nil,
                columns: ["ts"],
                columnTypes: [.timestamp(rawType: "TIMESTAMP")],
                displayFormats: [nil],
                dateFormat: .iso8601,
                nullDisplay: "NULL",
                smartValueDetection: true,
                systemTimeZoneGeneration: generation
            )
        }
        #expect(identity(generation: 1) == identity(generation: 1))
        #expect(identity(generation: 1) != identity(generation: 2))
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
