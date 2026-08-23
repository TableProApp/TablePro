import Foundation
import os

public enum OracleCellFormatting {
    public static let maxHexBytes = 4_096

    public enum TimestampStyle {
        case utc
        case local
        case zoned
    }

    public static let dateOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let utcFormatter: OSAllocatedUnfairLock<ISO8601DateFormatter> = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return OSAllocatedUnfairLock(uncheckedState: formatter)
    }()

    private static let localFormatter: OSAllocatedUnfairLock<ISO8601DateFormatter> = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = .current
        return OSAllocatedUnfairLock(uncheckedState: formatter)
    }()

    private static let zonedFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSxxxxx"
        return formatter
    }()

    public static func formatDate(_ date: Date) -> String {
        dateOnlyFormatter.string(from: date)
    }

    public static func formatTimestamp(_ date: Date, style: TimestampStyle) -> String {
        switch style {
        case .utc:
            return utcFormatter.withLockUnchecked { $0.string(from: date) }
        case .local:
            return localFormatter.withLockUnchecked { $0.string(from: date) }
        case .zoned:
            return zonedFormatter.string(from: date)
        }
    }

    public static func formatIntervalDS(
        days: Int,
        hours: Int,
        minutes: Int,
        seconds: Int,
        nanoseconds: Int
    ) -> String {
        let isNegative = days < 0 || hours < 0 || minutes < 0
            || seconds < 0 || nanoseconds < 0
        let sign = isNegative ? "-" : ""
        let base = String(
            format: "%@%d %02d:%02d:%02d",
            sign,
            abs(days),
            abs(hours),
            abs(minutes),
            abs(seconds)
        )
        let absNanos = abs(nanoseconds)
        if absNanos == 0 {
            return base
        }
        var fractional = String(format: "%09d", absNanos)
        while fractional.last == "0" {
            fractional.removeLast()
        }
        return "\(base).\(fractional)"
    }

    public static func formatIntervalYM(years: Int, months: Int) -> String {
        let isNegative = years < 0 || months < 0
        let sign = isNegative ? "-" : ""
        return String(format: "%@%d-%02d", sign, abs(years), abs(months))
    }

    public static func hexEncode(_ bytes: [UInt8]) -> String {
        let totalBytes = bytes.count
        let limit = min(totalBytes, maxHexBytes)
        let hex = bytes.prefix(limit).map { String(format: "%02x", $0) }.joined()
        if totalBytes > limit {
            return "\(hex)… (\(totalBytes) bytes)"
        }
        return hex
    }

    public static func unsupportedPlaceholder(typeName: String) -> String {
        "<unsupported: \(typeName)>"
    }
}
