//
//  WorkspaceRailTypeSelect.swift
//  TablePro
//

import Foundation

/// The keyboard's own answer to "which row does this typing mean", which the rail has to give
/// itself: a row now shows two semantic values, and AppKit's default matcher reads one string per
/// row from the cell's text field. Left to that default, typing would match the connection name and
/// the container only in the order they happen to be concatenated.
///
/// The range AppKit passes is circular: `startRow` is included, `endRow` is excluded, and the range
/// may wrap past the last row. `startRow == endRow` therefore means one complete scan rather than an
/// empty one, so the walk is a repeat-and-wrap that visits every row exactly once and stops.
internal enum WorkspaceRailTypeSelect {
    internal static let noMatch = -1

    internal static func nextMatch(
        in entries: [WorkspaceRailEntry],
        from startRow: Int,
        to endRow: Int,
        search: String
    ) -> Int {
        guard !search.isEmpty, entries.indices.contains(startRow) else { return noMatch }

        let stop = wrapped(endRow, count: entries.count)
        var row = startRow
        repeat {
            if matches(entries[row], search: search) { return row }
            row = wrapped(row + 1, count: entries.count)
        } while row != stop
        return noMatch
    }

    /// An out-of-range bound is a position on the same circle rather than a reason to stop
    /// answering: an exclusive end spelled as the row count names row 0, and taking it literally
    /// would turn every such search into "no match" and leave the strip deaf to typing.
    private static func wrapped(_ row: Int, count: Int) -> Int {
        let remainder = row % count
        return remainder < 0 ? remainder + count : remainder
    }

    private static func matches(_ entry: WorkspaceRailEntry, search: String) -> Bool {
        matchesPrefix(entry.connection.name, search: search)
            || matchesPrefix(entry.container, search: search)
    }

    private static func matchesPrefix(_ value: String, search: String) -> Bool {
        guard !value.isEmpty else { return false }
        return value.range(
            of: search,
            options: [.anchored, .caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        ) != nil
    }
}
