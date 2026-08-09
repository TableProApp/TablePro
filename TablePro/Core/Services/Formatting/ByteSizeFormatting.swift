//
//  ByteSizeFormatting.swift
//  TablePro
//

import Foundation

/// One rendering of sizes and durations for the whole app. Hand-rolled divide-by-1024
/// helpers disagreed with each other, hardcoded English unit names, and used a period
/// decimal separator in locales that use a comma.
internal enum ByteSizeFormatting {
    internal static func string(bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }

    internal static func string(bytes: Int) -> String {
        string(bytes: Int64(bytes))
    }

    internal static func string(bytes: UInt64) -> String {
        string(bytes: Int64(clamping: bytes))
    }

    /// Returns the input unchanged when it is not a number, because several servers report
    /// these values as opaque strings. `Double` parses "inf", "nan" and values past `Int64.max`,
    /// all of which trap on conversion, so a server reporting one of those has to fall through to
    /// the passthrough rather than take the app down.
    internal static func string(byteString: String) -> String {
        guard let value = Double(byteString), value.isFinite, value >= 0 else { return byteString }
        guard value < Double(Int64.max) else { return byteString }
        return string(bytes: Int64(value))
    }
}

internal enum DurationFormatting {
    internal static func string(seconds: Int) -> String {
        let duration = Duration.seconds(max(0, seconds))
        if seconds >= 3_600 {
            return duration.formatted(.units(allowed: [.hours, .minutes], width: .narrow))
        }
        if seconds >= 60 {
            return duration.formatted(.units(allowed: [.minutes, .seconds], width: .narrow))
        }
        return duration.formatted(.units(allowed: [.seconds], width: .narrow))
    }

    internal static func string(seconds: Double) -> String {
        string(seconds: Int(seconds.rounded()))
    }
}
