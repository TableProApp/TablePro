//
//  DateFormattingService.swift
//  TablePro
//
//  Centralized date formatting service that respects user settings.
//  Thread-safe singleton that formats dates according to DataGridSettings.dateFormat.
//

import Foundation

/// Centralized date formatting service that respects user settings
@MainActor
final class DateFormattingService {
    static let shared = DateFormattingService()

    // MARK: - Properties

    /// Cached formatter for current user-selected format
    private var formatter: DateFormatter
    private var dateOnlyFormatter: DateFormatter
    private var timeOnlyFormatter: DateFormatter

    /// Current date format option
    private(set) var currentFormat: DateFormatOption

    /// Parsers for common database date formats (ISO 8601, MySQL, PostgreSQL, SQLite)
    private let parsers: [DateFormatter]

    /// Index of the parser that succeeded most recently. Tried first on the next parse
    /// because consecutive cells in the same column share the same wire format.
    private var lastSuccessfulParserIndex: Int = 0

    /// Cache for formatted date strings to avoid repeated parsing
    private let formatCache = NSCache<NSString, NSString>()

    // MARK: - Initialization

    private init() {
        // Initialize with default format (ISO 8601)
        // Will be updated by AppSettingsManager after it completes initialization
        self.currentFormat = .iso8601
        self.formatter = Self.createFormatter(format: DateFormatOption.iso8601.formatString)
        self.dateOnlyFormatter = Self.createFormatter(format: DateFormatOption.iso8601.dateOnlyFormatString)
        self.timeOnlyFormatter = Self.createFormatter(format: DateFormatOption.iso8601.timeOnlyFormatString)
        self.parsers = Self.createParsers()
        formatCache.countLimit = 100_000
    }

    // MARK: - Public Methods

    /// Update the date format (called by AppSettingsManager when settings change)
    func updateFormat(_ format: DateFormatOption) {
        guard format != currentFormat else { return }
        currentFormat = format
        formatter = Self.createFormatter(format: format.formatString)
        dateOnlyFormatter = Self.createFormatter(format: format.dateOnlyFormatString)
        timeOnlyFormatter = Self.createFormatter(format: format.timeOnlyFormatString)
        // Clear cache when format changes since all cached values are now stale
        formatCache.removeAllObjects()
    }

    /// Format a date using current user settings
    /// - Parameter date: The date to format
    /// - Returns: Formatted date string
    func format(_ date: Date) -> String {
        formatter.string(from: date)
    }

    /// Format a string date value (parse then format)
    /// - Parameter dateString: Date string from database (ISO 8601, MySQL timestamp, etc.)
    /// - Parameter columnType: Column type, used to pick date-only / time-only / datetime variant
    /// - Returns: Formatted date string, or nil if unparseable
    func format(dateString: String, columnType: ColumnType? = nil) -> String? {
        let targetFormatter = formatter(for: columnType)
        let cacheKey = "\(formatBucket(for: columnType))|\(dateString)" as NSString
        if let cached = formatCache.object(forKey: cacheKey) {
            return cached.length == 0 ? nil : cached as String
        }

        if let date = parsers[lastSuccessfulParserIndex].date(from: dateString) {
            let result = targetFormatter.string(from: date)
            formatCache.setObject(result as NSString, forKey: cacheKey)
            return result
        }
        for index in parsers.indices where index != lastSuccessfulParserIndex {
            if let date = parsers[index].date(from: dateString) {
                lastSuccessfulParserIndex = index
                let result = targetFormatter.string(from: date)
                formatCache.setObject(result as NSString, forKey: cacheKey)
                return result
            }
        }

        formatCache.setObject("" as NSString, forKey: cacheKey)
        return nil
    }

    private func formatter(for columnType: ColumnType?) -> DateFormatter {
        switch columnType {
        case .date:
            return dateOnlyFormatter
        case .timestamp, .datetime:
            return columnType?.isTimeOnly == true ? timeOnlyFormatter : formatter
        default:
            return formatter
        }
    }

    private func formatBucket(for columnType: ColumnType?) -> String {
        switch columnType {
        case .date: return "d"
        case .timestamp, .datetime: return columnType?.isTimeOnly == true ? "t" : "dt"
        default: return "dt"
        }
    }

    // MARK: - Private Helper Methods

    private static func createFormatter(format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        formatter.locale = Locale.current
        formatter.timeZone = TimeZone.current
        return formatter
    }

    /// Create parsers for common database date formats
    /// Parsers are tried in order until one successfully parses the input.
    /// Formats WITHOUT explicit timezone info use the user's local timezone
    /// (database values like `2024-03-01 12:00:00` are naive — display as-is).
    /// Formats WITH timezone markers (`Z`, `+0000`) parse the embedded offset.
    /// - Returns: Array of DateFormatters for parsing
    private static func createParsers() -> [DateFormatter] {
        // (format, hasTimezone) — formats with timezone markers parse UTC/offset;
        // naive formats use user's local timezone so display matches the raw value.
        let formats: [(String, Bool)] = [
            ("yyyy-MM-dd HH:mm:ss", false),        // MySQL/PostgreSQL timestamp (most common)
            ("yyyy-MM-dd'T'HH:mm:ss", false),       // ISO 8601 (no timezone)
            ("yyyy-MM-dd'T'HH:mm:ssZ", true),       // ISO 8601 with timezone
            ("yyyy-MM-dd'T'HH:mm:ss.SSSZ", true),   // ISO 8601 with milliseconds and timezone
            ("yyyy-MM-dd", false),                   // Date only (MySQL DATE, PostgreSQL DATE)
            ("HH:mm:ss", false),                     // Time only (MySQL TIME)
        ]

        return formats.map { format, hasTimezone in
            let parser = DateFormatter()
            parser.dateFormat = format
            parser.locale = Locale(identifier: "en_US_POSIX")
            parser.timeZone = hasTimezone ? TimeZone(secondsFromGMT: 0) : TimeZone.current
            return parser
        }
    }
}
