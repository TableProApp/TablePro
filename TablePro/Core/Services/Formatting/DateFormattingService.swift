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

    /// Current date format option
    private(set) var currentFormat: DateFormatOption

    /// Parsers for common database date formats (ISO 8601, MySQL, PostgreSQL, SQLite)
    private let parsers: [DateFormatter]

    /// Cache for formatted date strings to avoid repeated parsing
    private let formatCache = NSCache<NSString, NSString>()

    // MARK: - Initialization

    private init() {
        // Initialize with default format (ISO 8601)
        // Will be updated by AppSettingsManager after it completes initialization
        self.currentFormat = .iso8601
        self.formatter = Self.createFormatter(for: .iso8601)
        self.parsers = Self.createParsers()
        // Limit cache to 10,000 entries to bound memory usage
        formatCache.countLimit = 10_000
    }

    // MARK: - Public Methods

    /// Update the date format (called by AppSettingsManager when settings change)
    func updateFormat(_ format: DateFormatOption) {
        guard format != currentFormat else { return }
        currentFormat = format
        formatter = Self.createFormatter(for: format)
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
    /// - Returns: Formatted date string, or nil if unparseable
    func format(dateString: String) -> String? {
        // Check cache first
        let cacheKey = dateString as NSString
        if let cached = formatCache.object(forKey: cacheKey) {
            // Empty string in cache means unparseable
            return cached.length == 0 ? nil : cached as String
        }

        // Try parsing with each parser
        for parser in parsers {
            if let date = parser.date(from: dateString) {
                let result = format(date)
                formatCache.setObject(result as NSString, forKey: cacheKey)
                return result
            }
        }

        // Could not parse - cache empty string to avoid re-parsing
        formatCache.setObject("" as NSString, forKey: cacheKey)
        return nil
    }

    // MARK: - Private Helper Methods

    /// Create formatter for a specific format option
    /// - Parameter option: The date format option
    /// - Returns: Configured DateFormatter
    private static func createFormatter(for option: DateFormatOption) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = option.formatString
        formatter.locale = Locale.current  // Use user's locale for localized formatting
        formatter.timeZone = TimeZone.current  // Use user's timezone
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
