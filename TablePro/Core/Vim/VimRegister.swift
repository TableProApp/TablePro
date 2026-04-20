//
//  VimRegister.swift
//  TablePro
//
//  Vim register for storing yanked/deleted text
//

import AppKit

/// Vim register for yank/delete/paste operations
struct VimRegister {
    /// The stored text content
    var text: String = ""

    /// Whether the text was yanked/deleted linewise (entire lines)
    var isLinewise: Bool = false

    /// Sync the register content to the system pasteboard
    func syncToPasteboard() {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
