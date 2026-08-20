//
//  DateEditingService.swift
//  TablePro
//
//  Writes an edited date/time value back in the shape it arrived in. The grammar that recognises
//  that shape belongs to DatabaseDateParser; this is only the write side. Distinct from
//  DateFormattingService, which formats for display using the user's locale and format preference.
//

import Foundation

enum TemporalComponents: Equatable {
    case dateOnly
    case timeOnly
    case dateAndTime
}

enum DateEditingService {
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

    /// An empty cell has no spelling to imitate, so the value is written in the user's own zone.
    /// Reading the picked instant in GMT instead wrote the UTC wall clock, which is the user's
    /// clock shifted by their offset and, for the hours after local midnight, the previous day.
    static func defaultString(from date: Date, columnType: ColumnType, timeZone: TimeZone = defaultTimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)

        if case .date = columnType {
            return dateString(from: components)
        }
        if columnType.isTimeOnly {
            return timeString(from: components)
        }
        return dateString(from: components) + " " + timeString(from: components)
    }

    /// The zone the picker opens in when the cell holds no value to read one from.
    static var defaultTimeZone: TimeZone { .current }

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
}
