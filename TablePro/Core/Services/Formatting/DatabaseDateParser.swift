//
//  DatabaseDateParser.swift
//  TablePro
//
//  The one grammar for the date spellings TablePro's drivers put on the wire. Cells arrive as text,
//  so the grid's display formatting, the chart's temporal axis and the cell editor all recover a
//  value from the same strings. A second grammar beside this one drifts from it.
//

import Foundation

/// The shape of the text a value was written in, kept so an edit can be written back the same way
/// instead of normalised into one house style.
struct TemporalLayout: Equatable {
    let hasDate: Bool
    let hasTime: Bool
    let dateTimeSeparator: String
    let fractionalSeconds: String?
    let timeZoneSuffix: String?
}

/// The instant, the zone it was written in, and the spelling it arrived as.
struct ParsedTemporalValue: Equatable {
    let date: Date
    /// The same value with its sub-second digits dropped.
    ///
    /// `Date` is a `Double` of seconds, which at 2024 resolves to about 119ns, so a fraction does
    /// not survive a round trip through it: `.000001` reads back as 953ns and `.999999999` rounds
    /// the whole second up. Display renders this one and splices the digits from the layout, so a
    /// value one microsecond before midnight prints its own second rather than the next one.
    let wholeSecond: Date
    let timeZone: TimeZone
    let layout: TemporalLayout

    /// The instant to plot on a chart's time axis, which is not always the instant the value names.
    ///
    /// Swift Charts labels a `Date` axis in the reader's zone and ignores `EnvironmentValues`,
    /// measured, so a naive value has to be handed the instant whose reader-zone wall clock is the
    /// text the grid prints. A value that carries its own offset names a real instant and is
    /// plotted as it is.
    var plottableDate: Date {
        guard layout.timeZoneSuffix == nil else { return date }
        var source = Calendar(identifier: .gregorian)
        source.timeZone = timeZone
        var reader = Calendar(identifier: .gregorian)
        reader.timeZone = .autoupdatingCurrent
        let wallClock = source.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .nanosecond],
            from: date
        )
        return reader.date(from: wallClock) ?? date
    }

    /// Whether the database supplied a zone at all. A `Z` suffix resolves to GMT and so does a
    /// value with no suffix, so the zone cannot tell them apart and only this can.
    var carriesItsOwnZone: Bool { layout.timeZoneSuffix != nil }
}

enum DatabaseDateParser {
    /// One expression rather than a list of `DateFormatter` patterns: it accepts every spelling
    /// MySQL, PostgreSQL, SQLite and SQL Server produce, and it reports the structure of the match,
    /// which a formatter cannot. `NSRegularExpression` is immutable and safe to match from any
    /// thread, so this needs no per-consumer instance.
    ///
    /// Month, day and hour take one or two digits because `DateFormatter` accepted an unpadded
    /// `2024-9-1` and dropping that would stop such a value rendering as a date at all.
    private static let pattern =
        #"^(?:(\d{4})-(\d{1,2})-(\d{1,2}))?(?:([ T])?(\d{1,2}):(\d{2}):(\d{2})(\.\d+)?)?(Z|[+-]\d{2}(?::?\d{2})?)?$"#

    private static let matcher = try? NSRegularExpression(pattern: pattern)

    private static let referenceDateComponents = (year: 2_000, month: 1, day: 1)

    /// A value carrying no offset is naive: `2024-03-01 12:00:00` names a wall clock, not an
    /// instant. It resolves in GMT, the one zone where every wall clock exists exactly once and
    /// never twice, so display, the cell picker and the write-back cancel exactly instead of
    /// accidentally. The zone travels with the value, so a write-back reproduces the same text.
    ///
    /// The reader's own zone could not do that. A wall clock inside a daylight-saving gap does not
    /// exist there, so `Calendar` legally moves it: `2024-03-10 02:30:00` read in New York drew as
    /// 03:30 and, once the picker was opened to change the date alone, wrote 03:30 back over it.
    /// Worse where a zone skipped a whole day: Samoa has no 2011-12-30, so a value stored on that
    /// date failed to parse at all and rendered as raw text with no picker.
    ///
    /// Anything that reads `date` without `timeZone` therefore holds a UTC anchor and wants
    /// `plottableDate` instead.
    private static var naiveTimeZone: TimeZone { .gmt }

    static func parse(_ rawValue: String?) -> ParsedTemporalValue? {
        guard let matcher, let raw = rawValue?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return nil
        }
        let range = NSRange(raw.startIndex..., in: raw)
        guard let match = matcher.firstMatch(in: raw, range: range) else { return nil }

        func group(_ index: Int) -> String? {
            let groupRange = match.range(at: index)
            guard groupRange.location != NSNotFound, let swiftRange = Range(groupRange, in: raw) else {
                return nil
            }
            return String(raw[swiftRange])
        }

        let year = group(1).flatMap(Int.init)
        let month = group(2).flatMap(Int.init)
        let day = group(3).flatMap(Int.init)
        let hour = group(5).flatMap(Int.init)
        let minute = group(6).flatMap(Int.init)
        let second = group(7).flatMap(Int.init)

        let hasDate = year != nil && month != nil && day != nil
        let hasTime = hour != nil && minute != nil && second != nil
        guard hasDate || hasTime else { return nil }

        let timeZoneSuffix = group(9)
        let timeZone = timeZoneSuffix.map(timeZone(fromSuffix:)) ?? naiveTimeZone
        let fractionalSeconds = group(8)

        var components = DateComponents()
        components.year = hasDate ? year : referenceDateComponents.year
        components.month = hasDate ? month : referenceDateComponents.month
        components.day = hasDate ? day : referenceDateComponents.day
        components.hour = hasTime ? hour : 0
        components.minute = hasTime ? minute : 0
        components.second = hasTime ? second : 0
        components.nanosecond = nanoseconds(from: fractionalSeconds)

        guard isInRange(components) else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var wholeSecondComponents = components
        wholeSecondComponents.nanosecond = 0
        guard let date = calendar.date(from: components),
              let wholeSecond = calendar.date(from: wholeSecondComponents),
              keepsItsDay(components, in: calendar, at: wholeSecond)
        else {
            return nil
        }

        let separator = group(4) ?? (hasDate && hasTime ? " " : "")
        let layout = TemporalLayout(
            hasDate: hasDate,
            hasTime: hasTime,
            dateTimeSeparator: separator,
            fractionalSeconds: fractionalSeconds,
            timeZoneSuffix: timeZoneSuffix
        )
        return ParsedTemporalValue(date: date, wholeSecond: wholeSecond, timeZone: timeZone, layout: layout)
    }

    static func date(from text: String) -> Date? {
        parse(text)?.date
    }

    /// `Calendar` rolls an out-of-range component over instead of refusing it, which would turn
    /// MySQL's `0000-00-00 00:00:00` into a plausible `0002-11-30`. `DateFormatter` refused those,
    /// and a value that is not a date has to keep rendering as the text it is.
    private static func isInRange(_ components: DateComponents) -> Bool {
        guard let month = components.month, let day = components.day,
              let hour = components.hour, let minute = components.minute, let second = components.second
        else { return false }
        return (1 ... 12).contains(month) && (1 ... 31).contains(day)
            && (0 ... 23).contains(hour) && (0 ... 59).contains(minute) && (0 ... 59).contains(second)
    }

    /// Catches the day a range check cannot, such as `2024-02-30`, which `Calendar` moves into
    /// March. Only the date is compared: a naive wall clock inside a spring-forward gap is legally
    /// shifted by an hour, and that value is still the day it says it is.
    ///
    /// It reads the whole-second instant, because a fraction near one second rounds the `Double`
    /// up: `2024-02-29 23:59:59.9999999999` landed on 1 March and was refused as not a date.
    private static func keepsItsDay(_ components: DateComponents, in calendar: Calendar, at date: Date) -> Bool {
        let rebuilt = calendar.dateComponents([.year, .month, .day], from: date)
        return rebuilt.year == components.year && rebuilt.month == components.month
            && rebuilt.day == components.day
    }

    /// Sub-second precision reaches the `Date` so a chart can separate points inside one second.
    /// The original text is kept in the layout as well, because rebuilding it from a `Double` would
    /// lose digits a database round-trip has to preserve.
    ///
    /// Counted in digits rather than scaled through a `Double`, which rounded `.789012` to
    /// 789_011_955 and, past nine digits, to a whole 1_000_000_000: `Calendar` then rolled that
    /// second forward and `keepsItsDay` rejected the value, so a high-precision timestamp on the
    /// last day of a month rendered as raw text.
    private static func nanoseconds(from fractionalSeconds: String?) -> Int {
        guard let fractionalSeconds else { return 0 }
        let digits = fractionalSeconds.dropFirst().prefix(9)
        guard !digits.isEmpty, let value = Int(digits) else { return 0 }
        return (0 ..< (9 - digits.count)).reduce(value) { scaled, _ in scaled * 10 }
    }

    static func timeZone(fromSuffix suffix: String) -> TimeZone {
        if suffix == "Z" { return .gmt }
        let sign = suffix.hasPrefix("-") ? -1 : 1
        let digits = suffix.dropFirst().filter(\.isNumber)
        let hours = Int(digits.prefix(2)) ?? 0
        let minutes = digits.count >= 4 ? (Int(digits.suffix(2)) ?? 0) : 0
        return TimeZone(secondsFromGMT: sign * (hours * 3_600 + minutes * 60)) ?? .gmt
    }
}
