//
//  SortableHeaderEmphasis.swift
//  TablePro
//

import AppKit

/// `NSTableRowView.isEmphasized` is key window *and* table focus, and the header has to answer the
/// same question or the two halves of one selection disagree.
internal enum SortableHeaderEmphasis {
    internal static func isEmphasized(tableViewHoldsFocus: Bool, isKeyWindow: Bool) -> Bool {
        tableViewHoldsFocus && isKeyWindow
    }

    /// A cell being edited or viewed takes focus in a text view the grid mounts in the table's
    /// scroll view, beside the table rather than inside it, so focus is resolved by ancestry from
    /// the scroll view rather than by identity with the table.
    internal static func holdsFocus(tableView: NSTableView?, in window: NSWindow?) -> Bool {
        guard let tableView, let responder = window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: tableView.enclosingScrollView ?? tableView)
    }
}
