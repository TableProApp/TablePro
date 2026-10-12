//
//  ForeignKeyLabelColumn.swift
//  TablePro
//

import Foundation

/// Which columns of the referenced table read as a row's name beside its key.
enum ForeignKeyLabelColumn {
    static let preferredNames = ["name", "title", "label", "username", "email", "code", "description"]

    /// `choice` is the reader's stored answer. A named column is honoured only when the table still
    /// carries it: the name reaches the query as a quoted identifier, so a preference left behind by
    /// a dropped column, or one written into defaults by hand, must never become one. **None** is
    /// honoured unconditionally and never checked against the table, because it names no identifier
    /// and so nothing about it can go stale.
    ///
    /// The key column is never a label, whatever is stored. It is already the first thing every row
    /// shows, and every layer below drops it: the select list refuses to name it twice, so choosing
    /// it used to be accepted, persisted, inherited by every other column pointing at the same
    /// table, and then silently rendered nothing.
    ///
    /// A choice that names only the key column is honoured as no label at all rather than handed
    /// back to the heuristic, because the old menu listed the key and choosing it was how a reader
    /// ended up with a key-only list. Falling through would give them a label they never asked for
    /// on the first launch after this. The fall-through is for a choice whose names the table no
    /// longer carries, which is a stale answer rather than an answer.
    ///
    /// Chosen columns come back in the referenced table's own column order rather than the order
    /// they were stored in, so the list reads the way the chooser does and needs no reordering
    /// control. A parent whose natural key is declared out of sequence therefore reads in
    /// declaration order, which is the cost of having no order to maintain.
    ///
    /// Only a column the search can actually pattern-match is offered automatically. A `LIKE`
    /// against a date, an integer, a `uuid`, an enum or an array is a type error on a strict
    /// engine, so a column the search cannot use is no use as a label either. A column the user
    /// names for themselves is still taken on their word, and the search simply carries the ones
    /// that can hold a predicate.
    static func resolve(
        columns: [ForeignKeyLookupColumn],
        keyColumn: String,
        choice: ForeignKeyLabelChoice
    ) -> [ForeignKeyLookupColumn] {
        switch choice {
        case .noLabel:
            return []
        case .columns(let preferred):
            let chosen = Set(preferred)
            let stored = selectable(columns, keyColumn: keyColumn).filter { chosen.contains($0.name) }
            if !stored.isEmpty { return stored }
            if columns.contains(where: { chosen.contains($0.name) }) { return [] }
        case .unset:
            break
        }
        let candidates = selectable(columns, keyColumn: keyColumn).filter(\.supportsPatternMatch)
        for name in preferredNames {
            if let match = candidates.first(where: { $0.name.lowercased() == name }) {
                return [match]
            }
        }
        return candidates.first.map { [$0] } ?? []
    }

    /// The columns a reader may choose between, which is every column of the referenced table but
    /// the one the key already shows.
    static func selectable(
        _ columns: [ForeignKeyLookupColumn],
        keyColumn: String
    ) -> [ForeignKeyLookupColumn] {
        columns.filter { $0.name != keyColumn }
    }
}
