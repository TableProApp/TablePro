//
//  ForeignKeyConstraintSpan.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// Whether a foreign key column is one of several the same constraint spans.
///
/// The value picker writes one column, so on a composite key it would offer a list of keys of which
/// only some pair with the values the row already holds in the constraint's other columns, and the
/// save is rejected on a reference the picker presented as valid. Such a column keeps the plain text
/// editor, which is what it had before the picker existed.
enum ForeignKeyConstraintSpan {
    /// Columns of one constraint share its name and its referenced table. A driver that reports no
    /// name cannot be asked, and an unnamed constraint is read as single-column: the answer there
    /// costs a picker that would probably have worked, never a write the server refuses.
    static func isMultiColumn(_ reference: ForeignKeyInfo, among all: [String: ForeignKeyInfo]) -> Bool {
        guard !reference.name.isEmpty else { return false }
        return all.values.contains {
            $0.column != reference.column
                && $0.name == reference.name
                && $0.referencedTable == reference.referencedTable
        }
    }
}
