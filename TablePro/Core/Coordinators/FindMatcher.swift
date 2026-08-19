//
//  FindMatcher.swift
//  TablePro
//

import Foundation

enum FindMatcher {
    static func isSearchable(_ columnType: ColumnType?) -> Bool {
        switch columnType {
        case .blob, .spatial: false
        default: true
        }
    }

    /// Columns a `LIKE` comparison can be built against without a cast. Postgres has no implicit
    /// integer to text conversion, so `id ILIKE '%abc%'` fails the whole query rather than matching
    /// nothing. Client-side matching is looser on purpose: it compares the text already on screen.
    static func isServerSearchable(_ columnType: ColumnType?) -> Bool {
        switch columnType {
        case .text, .enumType, .set, nil: true
        default: false
        }
    }

    static func matches(
        term: String,
        displayRowCount: Int,
        columnCount: Int,
        isColumnSearchable: (Int) -> Bool,
        cellText: (Int, Int) -> String?
    ) -> [FindMatch] {
        let needle = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, displayRowCount > 0, columnCount > 0 else { return [] }

        let searchableColumns = (0 ..< columnCount).filter(isColumnSearchable)
        guard !searchableColumns.isEmpty else { return [] }

        var found: [FindMatch] = []
        for displayRow in 0 ..< displayRowCount {
            for column in searchableColumns {
                guard let text = cellText(displayRow, column), !text.isEmpty else { continue }
                guard text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil else { continue }
                found.append(FindMatch(displayRow: displayRow, columnIndex: column))
            }
        }
        return found
    }

    static func nearestMatchIndex(to displayRow: Int, in matches: [FindMatch]) -> Int? {
        guard !matches.isEmpty else { return nil }
        if let forward = matches.firstIndex(where: { $0.displayRow >= displayRow }) { return forward }
        return 0
    }
}
