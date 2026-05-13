//
//  OracleCellFormatting.swift
//  OracleDriverPlugin
//

import Foundation

enum OracleCellFormatting {
    static let maxHexBytes = 4_096

    enum TimestampStyle {
        case utc
        case local
        case zoned
    }

    static let dateOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let utcFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    private static let localFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = .current
        return formatter
    }()

    private static let zonedFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds, .withTimeZone]
        return formatter
    }()

    static func formatDate(_ date: Date) -> String {
        dateOnlyFormatter.string(from: date)
    }

    static func formatTimestamp(_ date: Date, style: TimestampStyle) -> String {
        switch style {
        case .utc:
            return utcFormatter.string(from: date)
        case .local:
            return localFormatter.string(from: date)
        case .zoned:
            return zonedFormatter.string(from: date)
        }
    }

    static func formatIntervalDS(
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

    static func formatIntervalYM(years: Int, months: Int) -> String {
        let isNegative = years < 0 || months < 0
        let sign = isNegative ? "-" : ""
        return String(format: "%@%d-%02d", sign, abs(years), abs(months))
    }

    static func hexEncode(_ bytes: [UInt8]) -> String {
        let totalBytes = bytes.count
        let limit = min(totalBytes, maxHexBytes)
        let hex = bytes.prefix(limit).map { String(format: "%02x", $0) }.joined()
        if totalBytes > limit {
            return "\(hex)… (\(totalBytes) bytes)"
        }
        return hex
    }

    static func unsupportedPlaceholder(typeName: String) -> String {
        "<unsupported: \(typeName)>"
    }
}
