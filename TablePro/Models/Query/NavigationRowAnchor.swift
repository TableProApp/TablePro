//
//  NavigationRowAnchor.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// Which row a recorded navigation entry comes back to.
///
/// Pure, so the one rule that decides it can be tested without a grid, a selection or a change
/// manager behind it. The rule is that an anchor is only ever built from values the database
/// agrees with: a key the user has staged an edit to names a row that was never saved, and
/// discarding that edit clears the change record without putting the original value back, so an
/// anchor taken from it either finds nothing on the way back or selects whichever row happens to
/// carry that key by then.
internal enum NavigationRowAnchor {
    /// Nil when there is no usable anchor, which every caller already treats as "restore the view,
    /// leave the selection alone". That is the only safe answer here: a wrong row is worse than no
    /// row, because the reader cannot see that it is wrong.
    internal static func build(
        keyColumns: [String],
        columns: [String],
        values: ContiguousArray<PluginCellValue>,
        isModified: (Int) -> Bool
    ) -> [String: String]? {
        guard !keyColumns.isEmpty else { return nil }

        var anchor: [String: String] = [:]
        for name in keyColumns {
            guard let column = columns.firstIndex(of: name), column < values.count else { return nil }
            guard !isModified(column) else { return nil }
            guard let value = values[column].asText else { return nil }
            anchor[name] = value
        }
        return anchor.isEmpty ? nil : anchor
    }
}
