//
//  View+OptionalShortcut.swift
//  TablePro
//
//  View modifier for applying optional keyboard shortcuts.
//

import SwiftUI

internal extension View {
    /// Apply a keyboard shortcut only if one is provided.
    /// When `shortcut` is nil, no keyboard shortcut modifier is applied.
    @ViewBuilder
    func optionalKeyboardShortcut(_ shortcut: KeyboardShortcut?) -> some View {
        if let shortcut {
            self.keyboardShortcut(shortcut)
        } else {
            self
        }
    }
}
