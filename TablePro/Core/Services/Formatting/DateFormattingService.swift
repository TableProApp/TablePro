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
    private var dateTimeFormatter: DateFormatter
    private var dateOnlyFormatter: DateFormatter
    private var timeOnlyFormatter: DateFormatter

    /// Current date format option
    private(set) var currentFormat: DateFormatOption

    /// Cache for formatted date strings to avoid repeated parsing
    private let formatCache = NSCache<NSString, NSString>()

    // MARK: - Initialization

    private init() {
        // Will be updated by AppSettingsManager after it completes initialization
        self.currentFormat = .iso8601
        self.dateTimeFormatter = Self.createFormatter(for: .iso8601, components: .dateAndTime)
        self.dateOnlyFormatter = Self.createFormatter(for: .iso8601, components: .dateOnly)
        self.timeOnlyFormatter = Self.createFormatter(for: .iso8601, components: .timeOnly)
        formatCache.countLimit = 100_000
    }

    // MARK: - Public Methods

    /// Update the date format (called by AppSettingsManager when settings change)
    func updateFormat(_ format: DateFormatOption) {
        guard format != currentFormat else { return }
        currentFormat = format
        dateTimeFormatter = Self.createFormatter(for: format, components: .dateAndTime)
        dateOnlyFormatter = Self.createFormatter(for: format, components: .dateOnly)
        timeOnlyFormatter = Self.createFormatter(for: format, components: .timeOnly)
        // Clear cache when format changes since all cached values are now stale
        formatCache.removeAllObjects()
    }

    /// Format a date using current user settings
    /// - Parameter date: The date to format
    /// - Returns: Formatted date string
    func format(_ date: Date) -> String {
        dateTimeFormatter.timeZone = .current
        return dateTimeFormatter.string(from: date)
    }

    /// Format a string date value (parse then format).
    ///
    /// The value is rendered in the zone it was written in, not the reader's. A value carrying an
    /// offset names an instant in that offset, and the cell editor opens it there, so formatting it
    /// somewhere else made the grid and the picker disagree about which day the row held. A value
    /// with no offset is naive and parses in the reader's own zone, so this is the same zone it
    /// always used.
    ///
    /// The offset itself is printed with it, because a wall clock alone does not name an instant.
    /// It is the literal text the value arrived with, off the same layout the write-back reads. A
    /// pattern token cannot serve: it prints the formatter's own zone, which for a value carrying
    /// no offset is the reader's, so a `DATETIME` would gain an offset the database never held.
    ///
    /// The cache key needs no zone: the zone is read off the value, so the string determines it.
    /// - Parameter dateString: Date string from database (ISO 8601, MySQL timestamp, etc.)
    /// - Parameter columnType: Column type, used to pick date-only / time-only / datetime variant
    /// - Returns: Formatted date string, or nil if unparseable
    func format(dateString: String, columnType: ColumnType? = nil) -> String? {
        let components = temporalComponents(for: columnType)
        let cacheKey = "\(components.rawValue)|\(dateString)" as NSString
        if let cached = formatCache.object(forKey: cacheKey) {
            return cached.length == 0 ? nil : cached as String
        }

        guard let parsed = DatabaseDateParser.parse(dateString) else {
            formatCache.setObject("" as NSString, forKey: cacheKey)
            return nil
        }
        let targetFormatter = formatter(for: components)
        targetFormatter.timeZone = parsed.timeZone
        var result = targetFormatter.string(from: parsed.date)
        if currentFormat.rendersTime(for: components), let suffix = parsed.layout.timeZoneSuffix {
            result += suffix
        }
        formatCache.setObject(result as NSString, forKey: cacheKey)
        return result
    }

    /// A column with no type at all is read as a full timestamp, which is what the grid's own
    /// fallback did before the editor and the formatter shared this vocabulary.
    private func temporalComponents(for columnType: ColumnType?) -> TemporalComponents {
        guard let columnType else { return .dateAndTime }
        return DateEditingService.components(for: columnType)
    }

    private func formatter(for components: TemporalComponents) -> DateFormatter {
        switch components {
        case .dateOnly: return dateOnlyFormatter
        case .timeOnly: return timeOnlyFormatter
        case .dateAndTime: return dateTimeFormatter
        }
    }

    // MARK: - Private Helper Methods

    /// `dateFormat` is a fixed pattern, so it must be evaluated against a fixed locale and
    /// calendar. Following the user's region renders database timestamps in the Buddhist or
    /// Japanese calendar and reformats the very value the grid round-trips back to SQL.
    private static let fixedPatternLocale = Locale(identifier: "en_US_POSIX")

    private static func createFormatter(
        for format: DateFormatOption,
        components: TemporalComponents
    ) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = format.formatString(for: components)
        formatter.locale = fixedPatternLocale
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone.current
        return formatter
    }
}
