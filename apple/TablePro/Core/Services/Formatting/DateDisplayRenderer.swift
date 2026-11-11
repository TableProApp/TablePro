import Foundation

// One column shape's formatters: the pattern as the user chose it, and the same pattern with a slot
// for the sub-second digits a value may carry, used only for a value that arrived with a fraction.
private struct TemporalFormatters {
    let plain: DateFormatter
    let withFractionalSeconds: DateFormatter?
}

// Not Sendable: each value sets its formatter's zone, so one renderer serves one thread. Work off the
// main actor builds its own from the format option.
final class DateDisplayRenderer {
    let format: DateFormatOption

    private let dateTimeFormatters: TemporalFormatters
    private let dateOnlyFormatters: TemporalFormatters
    private let timeOnlyFormatters: TemporalFormatters

    // The only formatter that renders an instant rather than a wall clock the value carries, so its zone
    // is the reader's. `.autoupdatingCurrent` follows a system zone change; a captured `.current` is
    // frozen for the life of the process, measured.
    private let instantFormatter: DateFormatter

    private let formatCache = NSCache<NSString, NSString>()

    init(format: DateFormatOption) {
        self.format = format
        dateTimeFormatters = Self.createFormatters(for: format, components: .dateAndTime)
        dateOnlyFormatters = Self.createFormatters(for: format, components: .dateOnly)
        timeOnlyFormatters = Self.createFormatters(for: format, components: .timeOnly)
        instantFormatter = Self.createFormatter(pattern: format.formatString(for: .dateAndTime))
        instantFormatter.timeZone = .autoupdatingCurrent
        formatCache.countLimit = 100_000
    }

    func format(_ date: Date) -> String {
        instantFormatter.string(from: date)
    }

    // Nil when the text does not parse. The value renders in the zone it was written in, not the
    // reader's, so the grid and the cell editor agree on the day. A value with an offset prints that
    // offset as the literal text it arrived with: a pattern token prints the formatter's zone, which
    // would give a naive `DATETIME` an offset the database never held. The cache key needs no zone,
    // since the zone is read off the value.
    func format(dateString: String, columnType: ColumnType?) -> String? {
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
        if self.format.rendersTime(for: components), let suffix = parsed.layout.timeZoneSuffix {
            result += suffix
        }
        formatCache.setObject(result as NSString, forKey: cacheKey)
        return result
    }

    // A column with no type reads as a full timestamp, the grid's fallback before the editor and the
    // formatter shared this vocabulary.
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

    // The value's own sub-second digits are spliced in, not rendered, so `.789012` stays `.789012` and two
    // rows a microsecond apart never share a value filter entry. A fraction of only zeros is padding
    // (MySQL writes one on every `DATETIME(6)` row) and is dropped.
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

    // A fixed pattern needs a fixed locale and calendar: the user's region would render timestamps in
    // the Buddhist or Japanese calendar and change the value the grid writes back to SQL.
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
