//
//  ForeignKeyPickerEntry.swift
//  TablePro
//

import Foundation

/// One line of the foreign key picker's list: the term as typed, or a row from the referenced table.
internal enum ForeignKeyPickerEntry: Identifiable, Hashable {
    case literal(String)
    case row(ForeignKeyLookupService.Row)

    /// A row is identified by its position, never by its key. A foreign key may reference one
    /// column of a composite unique key, which is not unique on its own, and two entries sharing an
    /// id is undefined behaviour in the `List` that renders them.
    var id: String {
        switch self {
        case .literal(let text):
            return "literal\u{1}\(text)"
        case .row(let row):
            return "row\u{1}\(row.id)"
        }
    }

    /// The term leads the list only when it could be a key, so `Return` on a search that narrowed
    /// the list picks the row it narrowed to.
    ///
    /// A word typed into a picker on a numeric key is a search for a label, never a key: offering
    /// `Use "Big"` at the top of a list of one matching album, selected, made the obvious keystroke
    /// write `Big` into an integer column and left the one row the user was looking at unpicked.
    static func acceptsTypedKey(_ term: String, keyType: ColumnType?) -> Bool {
        guard let keyType else { return true }
        switch keyType {
        case .integer, .decimal:
            return ColumnTypeSQLQuoting.isNumericLiteral(term, for: keyType)
        default:
            return true
        }
    }

    static func build(
        rows: [ForeignKeyLookupService.Row],
        term: String,
        keyType: ColumnType?
    ) -> [ForeignKeyPickerEntry] {
        var entries: [ForeignKeyPickerEntry] = []
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty,
           !rows.contains(where: { $0.key == trimmed }),
           acceptsTypedKey(trimmed, keyType: keyType) {
            entries.append(.literal(trimmed))
        }
        entries.append(contentsOf: rows.map { .row($0) })
        return entries
    }

    /// The typed term first, then the row that already carries it, then the head of a narrowed list.
    ///
    /// The exact-key case is what stops a key being passed over: a search for `42` also matches
    /// every label containing 42, and those sort ahead of it whenever the key is longer.
    ///
    /// With nothing typed the cell's own value is selected instead, and nothing at all when the
    /// list does not carry it. Selecting the head of an unfiltered list there put the first row of
    /// the referenced table under `Return`, so opening the picker and pressing it wrote a key the
    /// user never chose over the one already in the cell.
    static func defaultSelection(
        in entries: [ForeignKeyPickerEntry],
        term: String,
        currentValue: String?
    ) -> ForeignKeyPickerEntry.ID? {
        if let literal = entries.first(where: { $0.isLiteral }) {
            return literal.id
        }
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return currentValue.flatMap { value in entries.first { $0.matchesKey(value) }?.id }
        }
        if let exact = entries.first(where: { $0.matchesKey(trimmed) }) {
            return exact.id
        }
        return entries.first?.id
    }

    private var isLiteral: Bool {
        if case .literal = self { return true }
        return false
    }

    private func matchesKey(_ value: String) -> Bool {
        if case .row(let row) = self { return row.key == value }
        return false
    }

    var committedValue: String {
        switch self {
        case .literal(let text):
            return text
        case .row(let row):
            return row.key
        }
    }
}
