//
//  SchemaDraftIssue.swift
//  TablePro
//

import Foundation

// A row the user began and did not finish. A blank row carries no intent and is ignored; a begun one is named
// here, never dropped from the statement in silence (#2691).
struct SchemaDraftIssue: Equatable, Identifiable, Sendable {
    let section: StructureSection
    // Zero-based position in the section's working list, or nil for an issue about the draft as a whole.
    let row: Int?
    let message: String

    var id: String { "\(section.rawValue)-\(row.map(String.init) ?? "-")-\(message)" }

    // Numbered from one, the way the grid's row gutter counts.
    var qualifiedMessage: String {
        guard let row else {
            return String(format: String(localized: "%1$@: %2$@"), section.displayName, message)
        }
        return String(
            format: String(localized: "%1$@ row %2$lld: %3$@"), section.displayName, Int64(row + 1), message
        )
    }
}
