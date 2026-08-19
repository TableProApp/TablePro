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

    private let parser = DatabaseDateParser()

    /// Cache for formatted date strings to avoid repeated parsing
    private let formatCache = NSCache<NSString, NSString>()

    // MARK: - Initialization

    private init() {
        // Will be updated by AppSettingsManager after it completes initialization
        self.currentFormat = .iso8601
        self.formatter = Self.createFormatter(format: DateFormatOption.iso8601.formatString)
        self.dateOnlyFormatter = Self.createFormatter(format: DateFormatOption.iso8601.dateOnlyFormatString)
        self.timeOnlyFormatter = Self.createFormatter(format: DateFormatOption.iso8601.timeOnlyFormatString)
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

        guard let date = parser.date(from: dateString) else {
            formatCache.setObject("" as NSString, forKey: cacheKey)
            return nil
        }
        let result = targetFormatter.string(from: date)
        formatCache.setObject(result as NSString, forKey: cacheKey)
        return result
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

    /// `dateFormat` is a fixed pattern, so it must be evaluated against a fixed locale and
    /// calendar. Following the user's region renders database timestamps in the Buddhist or
    /// Japanese calendar and reformats the very value the grid round-trips back to SQL.
    private static let fixedPatternLocale = Locale(identifier: "en_US_POSIX")

    private static func createFormatter(format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        formatter.locale = fixedPatternLocale
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone.current
        return formatter
    }
}
