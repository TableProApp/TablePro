//
//  SchemaDraftIssue.swift
//  TablePro
//

import Foundation

/// A row the user began and did not finish, named where the user can act on it.
///
/// The distinction this type exists to draw is between a row that is blank, which is the editor's
/// own placeholder and carries no intent, and a row that holds some of what a constraint needs and
/// not the rest. The first is ignored. The second used to be dropped from the generated statement
/// with no message at all, which is how a filled-in foreign key came to vanish between the grid and
/// the SQL Preview (#2691).
struct SchemaDraftIssue: Equatable, Identifiable, Sendable {
    let tab: StructureTab
    /// Zero-based position in the tab's grid, or nil for an issue about the draft as a whole.
    let row: Int?
    let message: String

    var id: String { "\(tab.rawValue)-\(row.map(String.init) ?? "-")-\(message)" }

    /// The message with its row and tab in front, for a reader who is looking at another tab.
    ///
    /// Rows are numbered from one here because that is how the grid's row gutter numbers them.
    var qualifiedMessage: String {
        guard let row else {
            return String(format: String(localized: "%1$@: %2$@"), tab.displayName, message)
        }
        return String(
            format: String(localized: "%1$@ row %2$lld: %3$@"), tab.displayName, Int64(row + 1), message
        )
    }
}
