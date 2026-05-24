//
//  DateEditingService.swift
//  TablePro
//
//  Parses a database date/time string for editing and writes the edited value
//  back in the same shape. Distinct from DateFormattingService, which formats
//  for display using the user's locale and format preference.
//

import Foundation

struct TemporalLayout: Equatable {
    let hasDate: Bool
    let hasTime: Bool
    let dateTimeSeparator: String
    let fractionalSeconds: String?
    let timeZoneSuffix: String?
}

struct ParsedTemporalValue: Equatable {
    let date: Date
    let timeZone: TimeZone
    let layout: TemporalLayout
}

enum TemporalComponents: Equatable {
    case dateOnly
    case timeOnly
    case dateAndTime
}

enum DateEditingService {
    private static let pattern =
        #"^(?:(\d{4})-(\d{2})-(\d{2}))?(?:([ T])?(\d{2}):(\d{2}):(\d{2})(\.\d+)?)?(Z|[+-]\d{2}(?::?\d{2})?)?$"#

    private static let matcher = try? NSRegularExpression(pattern: pattern)

    private static let referenceDateComponents = (year: 2_000, month: 1, day: 1)

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
        let timeZone = timeZoneSuffix.map(timeZone(fromSuffix:)) ?? .gmt

        var components = DateComponents()
        components.year = hasDate ? year : referenceDateComponents.year
        components.month = hasDate ? month : referenceDateComponents.month
        components.day = hasDate ? day : referenceDateComponents.day
        components.hour = hasTime ? hour : 0
        components.minute = hasTime ? minute : 0
        components.second = hasTime ? second : 0

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let date = calendar.date(from: components) else { return nil }

        let separator = group(4) ?? (hasDate && hasTime ? " " : "")
        let layout = TemporalLayout(
            hasDate: hasDate,
            hasTime: hasTime,
            dateTimeSeparator: separator,
            fractionalSeconds: group(8),
            timeZoneSuffix: timeZoneSuffix
        )
        return ParsedTemporalValue(date: date, timeZone: timeZone, layout: layout)
    }

    static func string(from date: Date, like parsed: ParsedTemporalValue) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = parsed.timeZone
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let layout = parsed.layout

        let datePart = dateString(from: components)
        let timePart = timeString(from: components) + (layout.fractionalSeconds ?? "")

        var result: String
        if layout.hasDate && layout.hasTime {
            result = datePart + layout.dateTimeSeparator + timePart
        } else if layout.hasDate {
            result = datePart
        } else {
            result = timePart
        }
        if let suffix = layout.timeZoneSuffix {
            result += suffix
        }
        return result
    }

    static func defaultString(from date: Date, columnType: ColumnType) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)

        if case .date = columnType {
            return dateString(from: components)
        }
        if columnType.isTimeOnly {
            return timeString(from: components)
        }
        return dateString(from: components) + " " + timeString(from: components)
    }

    static func components(for columnType: ColumnType) -> TemporalComponents {
        if case .date = columnType { return .dateOnly }
        if columnType.isTimeOnly { return .timeOnly }
        return .dateAndTime
    }

    private static func dateString(from components: DateComponents) -> String {
        String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private static func timeString(from components: DateComponents) -> String {
        String(format: "%02d:%02d:%02d", components.hour ?? 0, components.minute ?? 0, components.second ?? 0)
    }

    private static func timeZone(fromSuffix suffix: String) -> TimeZone {
        if suffix == "Z" { return .gmt }
        let sign = suffix.hasPrefix("-") ? -1 : 1
        let digits = suffix.dropFirst().filter(\.isNumber)
        let hours = Int(digits.prefix(2)) ?? 0
        let minutes = digits.count >= 4 ? (Int(digits.suffix(2)) ?? 0) : 0
        return TimeZone(secondsFromGMT: sign * (hours * 3_600 + minutes * 60)) ?? .gmt
    }
}
