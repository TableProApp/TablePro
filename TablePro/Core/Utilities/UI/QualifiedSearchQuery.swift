//
//  QualifiedSearchQuery.swift
//  TablePro
//

import Foundation

/// A search that says where an object lives as well as what it is called: `attendance.timesheet`,
/// `attendance.` for everything in one schema, or `shop.attendance.timesheet`.
///
/// It parses text that is still being typed rather than finished SQL, so it is lenient where an
/// identifier parser would refuse: spaces around a dot are ignored, an unterminated quote runs to
/// the end of the text, and the quotes of every engine the app speaks are accepted, `"x"`, `[x]`
/// and `` `x` ``, each with its doubled closing character as an escape. A dot inside quotes belongs
/// to the name. Text with no unquoted dot is not qualified, and neither is text with an empty
/// container such as `.orders` or `a..b`, so both stay ordinary searches.
internal struct QualifiedSearchQuery: Equatable, Sendable {
    /// Outermost first: `["shop", "attendance"]` for `shop.attendance.timesheet`.
    internal let containers: [String]
    /// Empty when the text ends in a dot, which asks for everything in the container.
    internal let name: String

    internal init?(_ text: String) {
        let segments = Self.segments(of: text)
        guard segments.count > 1, let name = segments.last else { return nil }
        let containers = Array(segments.dropLast())
        guard !containers.contains(where: \.isEmpty) else { return nil }
        self.containers = containers
        self.name = name
    }

    /// Pairs each container the query names with the part of `location` it has to match, right to
    /// left, so `attendance.timesheet` reaches the schema of `[database, schema]` and
    /// `shop.attendance.timesheet` reaches both. Nil when the query names more containers than the
    /// location has, which no match can satisfy.
    internal func containerPairs(with location: [String]) -> [(query: String, candidate: String)]? {
        guard containers.count <= location.count else { return nil }
        return Array(zip(containers, location.suffix(containers.count)))
    }

    /// Where an object lives, outermost first, as a qualified query addresses it. A schema that
    /// only repeats the database, which is how some engines report a schema-less object, is not a
    /// second level.
    internal static func location(database: String?, schema: String?) -> [String] {
        var location: [String] = []
        if let database, !database.isEmpty {
            location.append(database)
        }
        if let schema, !schema.isEmpty, schema != database {
            location.append(schema)
        }
        return location
    }

    private static let closingQuotes: [Character: Character] = ["\"": "\"", "`": "`", "[": "]"]

    private static func segments(of text: String) -> [String] {
        var segments: [String] = []
        var current = ""
        var closingQuote: Character?
        var characters = Array(text)[...]
        while let character = characters.popFirst() {
            if let closing = closingQuote {
                guard character == closing else {
                    current.append(character)
                    continue
                }
                if characters.first == closing {
                    current.append(closing)
                    characters.removeFirst()
                } else {
                    closingQuote = nil
                }
                continue
            }
            if let closing = closingQuotes[character] {
                closingQuote = closing
            } else if character == "." {
                segments.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        segments.append(current.trimmingCharacters(in: .whitespaces))
        return segments
    }
}
