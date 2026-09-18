//
//  GridMenuOption.swift
//  TablePro
//
//  One entry in a data grid cell's chevron menu.
//

import Foundation

/// An entry in the menu a data grid cell's chevron opens.
///
/// A closed vocabulary (YES/NO, a referential action, an index type) is a list of `.value` entries and
/// nothing else. An open vocabulary such as a column default adds `.sectionHeader` to group the
/// engine's own expressions, `.clear` to remove the value entirely, and `.custom` to reach a value the
/// menu cannot spell.
enum GridMenuOption: Equatable, Hashable {
    /// A selectable entry. `title` is what the menu shows, `sql` is what the cell is set to; the two
    /// differ wherever the value is not its own best label, as `Empty string` is for `''`.
    case value(title: String, sql: String)
    case sectionHeader(String)
    /// Sets the cell to no value at all, which is a different state from any text the menu can offer.
    case clear(title: String)
    /// Opens the custom value editor.
    case custom(title: String)

    var sql: String? {
        switch self {
        case .value(_, let sql): sql
        case .sectionHeader, .clear, .custom: nil
        }
    }

    static func values(_ titles: [String]) -> [GridMenuOption] {
        titles.map { .value(title: $0, sql: $0) }
    }
}
