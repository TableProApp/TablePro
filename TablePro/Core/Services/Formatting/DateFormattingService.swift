//
//  DateFormattingService.swift
//  TablePro
//
//  Centralized date formatting service that respects user settings.
//  Thread-safe singleton that formats dates according to DataGridSettings.dateFormat.
//

import Combine
import Foundation

/// The pair of formatters one column shape needs: the pattern as the user chose it, and the same
/// pattern with a slot for the sub-second digits a value may carry.
private struct TemporalFormatters {
    let plain: DateFormatter
    let withFractionalSeconds: DateFormatter?
}

/// Centralized date formatting service that respects user settings
@MainActor
final class DateFormattingService {
    static let shared = DateFormattingService()

    // MARK: - Properties

    /// Cached formatters for the current user-selected format.
    ///
    /// Two per column shape, not one: the marked variant carries a quoted slot after the seconds
    /// and is used only for a value that arrived with a fraction, so a value without one pays
    /// neither the second format nor the splice.
    private var dateTimeFormatters: TemporalFormatters
    private var dateOnlyFormatters: TemporalFormatters
    private var timeOnlyFormatters: TemporalFormatters

    /// The one formatter that renders an instant rather than a wall clock the value already
    /// carries, so it is the only one whose zone is the reader's.
    ///
    /// It holds `.autoupdatingCurrent`, which follows a system time zone change with no
    /// reassignment; a captured `.current` is frozen for the life of the process, measured. Its
    /// pattern still tracks the user's chosen format, so `updateFormat` rewrites that and never
    /// the zone.
    private let instantFormatter: DateFormatter

    private var systemTimeZoneObserver: NSObjectProtocol?

    /// Rises each time the Mac's zone moves, so a display cache built in the old one compares
    /// unequal and is replaced rather than repaired.
    private(set) var systemTimeZoneGeneration = 0

    /// Current date format option
    private(set) var currentFormat: DateFormatOption

    /// Cache for formatted date strings to avoid repeated parsing
    private let formatCache = NSCache<NSString, NSString>()

    // MARK: - Initialization

    private init() {
        // Will be updated by AppSettingsManager after it completes initialization
        self.currentFormat = .iso8601
        self.dateTimeFormatters = Self.createFormatters(for: .iso8601, components: .dateAndTime)
        self.dateOnlyFormatters = Self.createFormatters(for: .iso8601, components: .dateOnly)
        self.timeOnlyFormatters = Self.createFormatters(for: .iso8601, components: .timeOnly)
        self.instantFormatter = Self.createFormatter(pattern: DateFormatOption.iso8601.formatString(for: .dateAndTime))
        self.instantFormatter.timeZone = .autoupdatingCurrent
        formatCache.countLimit = 100_000
        observeSystemTimeZone()
    }

    /// `NSSystemTimeZoneDidChange` documents no posting thread, and this app has already shipped a
    /// crash from assuming one, so the observer names the main queue and hops explicitly.
    private func observeSystemTimeZone() {
        systemTimeZoneObserver = NotificationCenter.default.addObserver(
            forName: .NSSystemTimeZoneDidChange,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                DateFormattingService.shared.systemTimeZoneGeneration += 1
                AppEvents.shared.systemTimeZoneChanged.send(())
            }
        }
    }

    // MARK: - Public Methods

    /// Update the date format (called by AppSettingsManager when settings change)
    func updateFormat(_ format: DateFormatOption) {
        guard format != currentFormat else { return }
        currentFormat = format
        dateTimeFormatters = Self.createFormatters(for: format, components: .dateAndTime)
        dateOnlyFormatters = Self.createFormatters(for: format, components: .dateOnly)
        timeOnlyFormatters = Self.createFormatters(for: format, components: .timeOnly)
        instantFormatter.dateFormat = format.formatString(for: .dateAndTime)
        // Clear cache when format changes since all cached values are now stale
        formatCache.removeAllObjects()
    }

    /// Format a date using current user settings
    /// - Parameter date: The date to format
    /// - Returns: Formatted date string
    func format(_ date: Date) -> String {
        instantFormatter.string(from: date)
    }

    /// Format a string date value (parse then format).
    ///
    /// The value is rendered in the zone it was written in, not the reader's. A value carrying an
    /// offset names an instant in that offset, and the cell editor opens it there, so formatting it
    /// somewhere else made the grid and the picker disagree about which day the row held. A value
    /// with no offset is naive and parses in GMT, so it prints the wall clock it was written with
    /// whatever zone the reader is in.
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
        var result = render(parsed, with: formatters(for: components))
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

    private func formatters(for components: TemporalComponents) -> TemporalFormatters {
        switch components {
        case .dateOnly: return dateOnlyFormatters
        case .timeOnly: return timeOnlyFormatters
        case .dateAndTime: return dateTimeFormatters
        }
    }

    /// The value's own sub-second digits are spliced in, not rendered, so `.5` stays `.5` and
    /// `.789012` stays `.789012`. Two rows one microsecond apart used to draw the same text, which
    /// also collapsed them into one entry in the column's value filter.
    ///
    /// A fraction of nothing but zeros is padding rather than precision, and MySQL writes one on
    /// every row of a `DATETIME(6)` where PostgreSQL trims it at the server. It is dropped, so such
    /// a column reads exactly as it did before and only a value that carries real digits grows.
    private func render(_ parsed: ParsedTemporalValue, with formatters: TemporalFormatters) -> String {
        guard let fractionalSeconds = parsed.layout.fractionalSeconds,
              fractionalSeconds.contains(where: { $0 != "0" && $0 != "." }),
              let marked = formatters.withFractionalSeconds
        else {
            formatters.plain.timeZone = parsed.timeZone
            return formatters.plain.string(from: parsed.wholeSecond)
        }
        marked.timeZone = parsed.timeZone
        return marked.string(from: parsed.wholeSecond)
            .replacingOccurrences(of: String(DateFormatOption.fractionalSecondsMarker), with: fractionalSeconds)
    }

    // MARK: - Private Helper Methods

    /// `dateFormat` is a fixed pattern, so it must be evaluated against a fixed locale and
    /// calendar. Following the user's region renders database timestamps in the Buddhist or
    /// Japanese calendar and reformats the very value the grid round-trips back to SQL.
    private static let fixedPatternLocale = Locale(identifier: "en_US_POSIX")

    private static func createFormatters(
        for format: DateFormatOption,
        components: TemporalComponents
    ) -> TemporalFormatters {
        TemporalFormatters(
            plain: createFormatter(pattern: format.formatString(for: components)),
            withFractionalSeconds: format.fractionalSecondsFormatString(for: components)
                .map(createFormatter(pattern:))
        )
    }

    private static func createFormatter(pattern: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = pattern
        formatter.locale = fixedPatternLocale
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone.current
        return formatter
    }
}
