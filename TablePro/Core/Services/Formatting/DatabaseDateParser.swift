//
//  DatabaseDateParser.swift
//  TablePro
//
//  The date spellings TablePro's drivers put on the wire, in one place. Cells arrive as text, so
//  both the grid's display formatting and the chart's temporal axis have to recover a Date from
//  the same strings.
//

import Foundation

/// Not thread safe: `DateFormatter` is not `Sendable`, so each consumer owns an instance inside its
/// own isolation domain rather than sharing one.
final class DatabaseDateParser {
    /// Tried in order until one succeeds. Formats without a zone marker are read in the user's
    /// time zone, because a database value like `2024-03-01 12:00:00` is naive and must display
    /// as written. Formats with a zone marker carry their own offset.
    ///
    /// Coverage is measured, not assumed: `Z` accepts `Z`, `+0700` and `+07:00` when parsing, and
    /// `SSSSSS` accepts any number of fractional digits, so nine patterns cover every spelling
    /// MySQL, PostgreSQL, SQLite and SQL Server produce.
    private static let formats: [(pattern: String, hasTimeZone: Bool)] = [
        ("yyyy-MM-dd HH:mm:ss", false),
        ("yyyy-MM-dd'T'HH:mm:ss", false),
        ("yyyy-MM-dd'T'HH:mm:ssZ", true),
        ("yyyy-MM-dd'T'HH:mm:ss.SSSZ", true),
        ("yyyy-MM-dd", false),
        ("HH:mm:ss", false),
        ("yyyy-MM-dd HH:mm:ssXXXXX", true),
        ("yyyy-MM-dd HH:mm:ss.SSSSSSXXXXX", true),
        ("yyyy-MM-dd HH:mm:ss.SSSSSS", false),
    ]

    private let parsers: [DateFormatter]

    /// Consecutive cells in one column share a wire format, so the last winner is tried first.
    private var lastSuccessfulIndex = 0

    init() {
        parsers = Self.formats.map { format in
            let parser = DateFormatter()
            parser.dateFormat = format.pattern
            parser.locale = Locale(identifier: "en_US_POSIX")
            parser.calendar = Calendar(identifier: .gregorian)
            parser.timeZone = format.hasTimeZone ? TimeZone(secondsFromGMT: 0) : TimeZone.current
            return parser
        }
    }

    func date(from text: String) -> Date? {
        if let date = parsers[lastSuccessfulIndex].date(from: text) {
            return date
        }
        for index in parsers.indices where index != lastSuccessfulIndex {
            if let date = parsers[index].date(from: text) {
                lastSuccessfulIndex = index
                return date
            }
        }
        return nil
    }
}
