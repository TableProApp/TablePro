//
//  RowGenerationValueText.swift
//  TablePro
//

import Foundation

// Values are written as the text every engine reads for the type, without a formatter or a time zone, so the same
// seed gives the same text on every Mac.
internal enum RowGenerationValueText {
    internal static let secondsPerDay: Int64 = 86_400

    // Days since 1970-01-01, by Howard Hinnant's `days_from_civil`.
    internal static func dayNumber(year: Int64, month: Int64, day: Int64) -> Int64 {
        let shiftedYear = month <= 2 ? year - 1 : year
        let era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) / 400
        let yearOfEra = shiftedYear - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    internal static func dayNumber(of date: Date, calendar: Calendar) -> Int64 {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return dayNumber(year: Int64(parts.year ?? 1_970), month: Int64(parts.month ?? 1), day: Int64(parts.day ?? 1))
    }

    internal static func civil(fromDayNumber days: Int64) -> (year: Int64, month: Int64, day: Int64) {
        let shifted = days + 719_468
        let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
        let dayOfEra = shifted - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthPrime = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthPrime + 2) / 5 + 1
        let month = monthPrime < 10 ? monthPrime + 3 : monthPrime - 9
        return (yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }

    internal static func date(dayNumber: Int64) -> String {
        let parts = civil(fromDayNumber: dayNumber)
        return "\(padded(parts.year, 4))-\(padded(parts.month, 2))-\(padded(parts.day, 2))"
    }

    internal static func time(secondOfDay: Int64) -> String {
        "\(padded(secondOfDay / 3_600, 2)):\(padded(secondOfDay / 60 % 60, 2)):\(padded(secondOfDay % 60, 2))"
    }

    internal static func dateTime(second: Int64) -> String {
        let day = second >= 0 ? second / secondsPerDay : (second - secondsPerDay + 1) / secondsPerDay
        return "\(date(dayNumber: day)) \(time(secondOfDay: second - day * secondsPerDay))"
    }

    // A count of steps of 10^-scale, so 12345 at scale 2 is "123.45" with no binary rounding on the way.
    internal static func decimal(steps: Int64, scale: Int) -> String {
        guard scale > 0 else { return String(steps) }
        let magnitude = steps.magnitude
        let divisor = UInt64(pow(10, Double(scale)))
        let whole = magnitude / divisor
        let fraction = String(magnitude % divisor)
        let paddedFraction = String(repeating: "0", count: max(0, scale - fraction.count)) + fraction
        return "\(steps < 0 ? "-" : "")\(whole).\(paddedFraction)"
    }

    internal static func steps(of value: Double, scale: Int) -> Int64 {
        let scaled = (value * pow(10, Double(scale))).rounded()
        guard scaled.isFinite else { return 0 }
        return Int64(max(min(scaled, Double(Int64.max / 2)), Double(Int64.min / 2)))
    }

    private static func padded(_ value: Int64, _ width: Int) -> String {
        let text = String(value.magnitude)
        let zeros = String(repeating: "0", count: max(0, width - text.count))
        return (value < 0 ? "-" : "") + zeros + text
    }
}
