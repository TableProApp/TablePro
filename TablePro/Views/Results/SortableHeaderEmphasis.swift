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

    /// A cell being edited puts the field editor in the responder chain below the table, so focus
    /// is resolved by ancestry rather than by identity.
    internal static func holdsFocus(tableView: NSTableView?, in window: NSWindow?) -> Bool {
        guard let tableView, let responder = window?.firstResponder as? NSView else { return false }
        return responder === tableView || responder.isDescendant(of: tableView)
    }
}
