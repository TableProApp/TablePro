//
//  PostgresArrayDelimiter.swift
//  TablePro
//

import Foundation

/// The character PostgreSQL puts between an array's elements, its `pg_type.typdelim`.
///
/// It belongs to the element type, not to the array, and it is almost always a comma. `box` is the
/// exception, and it is the only type in the whole catalog that is: measured on PostgreSQL 17.11,
/// `SELECT typname FROM pg_type WHERE typdelim <> ','` returns `box` and its array `_box` and
/// nothing else. A `box[]` therefore arrives as `{(3,4),(1,2);(7,8),(5,6)}`, and reading it with a
/// comma splits one box into four fragments.
///
/// An extension is free to declare another, so `scripts/check-postgres-array-delimiters.sh` diffs
/// this against a live server rather than leaving it as a fact nothing re-checks.
internal enum PostgresArrayDelimiter {
    internal static let `default`: Character = ","

    /// Keyed by the element type's own name, lowercased, with any parameters and schema qualifier
    /// already stripped by `elementTypeName`.
    private static let byElementType: [String: Character] = ["box": ";"]

    internal static func forElementType(_ rawTypeName: String?) -> Character {
        guard let name = elementTypeName(rawTypeName) else { return `default` }
        return byElementType[name] ?? `default`
    }

    /// The delimiter an array column's values use, taken from the element it declares.
    internal static func forColumn(_ type: ColumnType) -> Character {
        forElementType(type.arrayElement?.rawType)
    }

    /// `format_type` can hand back `pg_catalog.box` or a parameterized spelling, and the classifier
    /// keeps whatever the catalog said, so the name is normalized before the lookup.
    private static func elementTypeName(_ rawTypeName: String?) -> String? {
        guard let rawTypeName else { return nil }
        let base = rawTypeName.prefix { $0 != "(" }
        let unqualified = base.split(separator: ".").last ?? base[...]
        let name = unqualified.trimmingCharacters(in: .whitespaces).lowercased()
        return name.isEmpty ? nil : name
    }
}
