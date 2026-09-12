//
//  ForeignKeyLabelColumn.swift
//  TablePro
//

import Foundation

/// Which column of the referenced table reads as a row's name beside its key.
enum ForeignKeyLabelColumn {
    static let preferredNames = ["name", "title", "label", "username", "email", "code", "description"]

    /// `choice` is the reader's stored answer. A named column is honoured only when the table still
    /// carries it: the name reaches the query as a quoted identifier, so a preference left behind by
    /// a dropped column, or one written into defaults by hand, must never become one. **None** is
    /// honoured unconditionally and never checked against the table, because it names no identifier
    /// and so nothing about it can go stale.
    ///
    /// Only a column the search can actually pattern-match is offered automatically. A `LIKE`
    /// against a date, an integer, a `uuid`, an enum or an array is a type error on a strict
    /// engine, so a column the search cannot use is no use as a label either. A column the user
    /// names for themselves is still taken on their word.
    static func resolve(
        columns: [ForeignKeyLookupColumn],
        keyColumn: String,
        choice: ForeignKeyLabelChoice
    ) -> ForeignKeyLookupColumn? {
        switch choice {
        case .noLabel:
            return nil
        case .column(let preferred):
            if let stored = columns.first(where: { $0.name == preferred }) { return stored }
        case .unset:
            break
        }
        let candidates = columns.filter { $0.name != keyColumn && $0.supportsPatternMatch }
        for name in preferredNames {
            if let match = candidates.first(where: { $0.name.lowercased() == name }) {
                return match
            }
        }
        return candidates.first
    }
}
