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

    /// A throughput figure, rendered as the size per second: "142 KB/s". Rounded to whole bytes
    /// first, because the size formatter takes an integer and a rate never arrives as one.
    internal static func string(bytesPerSecond: Double) -> String {
        let rounded = bytesPerSecond.rounded()
        guard rounded.isFinite, rounded >= 0, rounded < Double(Int64.max) else { return "" }
        return String(format: String(localized: "%@/s"), string(bytes: Int64(rounded)))
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

    internal static func string(mebibytes: Int64) -> String {
        string(bytes: SaturatingArithmetic.product(mebibytes, 1_048_576))
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
        string(seconds: SaturatingArithmetic.int(seconds.rounded()))
    }

    internal static func string(milliseconds: Int) -> String {
        string(microseconds: SaturatingArithmetic.product(milliseconds, 1_000))
    }

    // Slow log entries mostly finish within a second, which the whole-second form shows as 0s.
    internal static func string(microseconds: Int) -> String {
        let microseconds = max(0, microseconds)
        let milliseconds = microseconds / 1_000 + (microseconds % 1_000 >= 500 ? 1 : 0)
        if milliseconds >= 1_000 {
            return string(seconds: Double(microseconds) / 1_000_000)
        }
        if milliseconds >= 1 {
            return Duration.milliseconds(milliseconds).formatted(.units(allowed: [.milliseconds], width: .narrow))
        }
        return Duration.microseconds(microseconds).formatted(.units(allowed: [.microseconds], width: .narrow))
    }
}

// A number a server reports for display pins to the end of the range instead of trapping.
internal enum SaturatingArithmetic {
    // Truncates toward zero like `Int(_:)`; NaN reads as zero.
    internal static func int(_ value: Double) -> Int {
        if value.isNaN { return 0 }
        if value >= Double(Int.max) { return .max }
        if value <= Double(Int.min) { return .min }
        return Int(value)
    }

    internal static func product<Value: FixedWidthInteger>(_ lhs: Value, _ rhs: Value) -> Value {
        let (result, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        guard overflow else { return result }
        return (lhs < 0) == (rhs < 0) ? .max : .min
    }
}
