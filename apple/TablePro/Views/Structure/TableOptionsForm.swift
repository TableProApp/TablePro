//
//  TableOptionsForm.swift
//  TablePro
//

import Foundation
import TableProPluginKit

// The lists the table options pickers offer. A Picker whose selection matches no tag shows nothing selected, so
// the value the table holds is always an item, whether the catalog lists it or not (MySQL 8.0 before .30 reports
// `utf8`, which the catalog spells `utf8mb3`).
enum TableOptionsForm {
    struct Choice: Hashable, Identifiable {
        let name: String
        let isDefault: Bool

        var id: String { name }
        var title: String { TableOptionsForm.collationTitle(name, isDefault: isDefault) }
    }

    static func collationTitle(_ name: String, isDefault: Bool) -> String {
        isDefault ? String(format: String(localized: "%@ (default)"), name) : name
    }

    static func characterSets(in catalog: TableOptionsCatalog?, keeping current: String?) -> [String] {
        keeping(current, in: catalog?.characterSets.map(\.name) ?? [])
    }

    static func collations(
        in catalog: TableOptionsCatalog?,
        characterSet: String?,
        keeping current: String?
    ) -> [Choice] {
        let set = characterSet.flatMap { catalog?.characterSet(named: $0) }
        let listed = (set?.collations ?? []).map { Choice(name: $0, isDefault: $0 == set?.defaultCollation) }
        guard let current, !current.isEmpty, !listed.contains(where: { matches($0.name, current) }) else { return listed }
        return [Choice(name: current, isDefault: false)] + listed
    }

    static func engines(in catalog: TableOptionsCatalog?, keeping current: String?) -> [Choice] {
        let names = keeping(current, in: catalog?.engines ?? [])
        return names.map { Choice(name: $0, isDefault: matches($0, catalog?.defaultEngine)) }
    }

    // A character set without a collation takes its default, and one from the previous set is an error (1253).
    static func selectingCharacterSet(_ name: String, in options: TableOptions, catalog: TableOptionsCatalog?) -> TableOptions {
        var next = options
        next.characterSet = name
        next.collation = catalog?.defaultCollation(for: name)?.nilIfEmpty
        return next
    }

    static func defaultCollation(of name: String?, in catalog: TableOptionsCatalog?) -> String? {
        name.flatMap { catalog?.defaultCollation(for: $0) }?.nilIfEmpty
    }

    private static func keeping(_ current: String?, in names: [String]) -> [String] {
        guard let current, !current.isEmpty, !names.contains(where: { matches($0, current) }) else { return names }
        return [current] + names
    }

    private static func matches(_ lhs: String, _ rhs: String?) -> Bool {
        guard let rhs else { return false }
        return lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }
}

// What the Next Auto Increment field holds. Past the AUTO_INCREMENT column's type the next INSERT fails with 1467,
// so the range is the draft column's, which a type change in the same save moves.
enum AutoIncrementEntry: Equatable {
    case empty
    case value(UInt64)
    case invalid(maximum: UInt64)

    init(_ text: String, maximum: UInt64, original: UInt64? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            self = .empty
            return
        }
        guard trimmed.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }), let value = UInt64(trimmed) else {
            self = .invalid(maximum: maximum)
            return
        }
        // An exhausted counter sits one past the column's type; the server's own value is never the user's error.
        guard value == original || (1...maximum).contains(value) else {
            self = .invalid(maximum: maximum)
            return
        }
        self = .value(value)
    }

    // MySQL reads `INT UNSIGNED` back as INT with the column's own flag set.
    static func maximum(for column: EditableColumnDefinition) -> UInt64 {
        AutoIncrementRange.maximum(forColumnType: column.dataType, unsigned: column.unsigned) ?? .max
    }

    var message: String? {
        guard case .invalid(let maximum) = self else { return nil }
        return String(format: String(localized: "Enter a whole number from 1 to %@."), String(maximum))
    }
}
