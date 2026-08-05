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

    /// Apply a data-grid action's shortcut, except while a focused text input owns
    /// that combination. AppKit matches a menu key equivalent before the first
    /// responder sees `keyDown`, and it consumes the event whether the item is
    /// enabled or not, so dropping the key equivalent is the only way to hand the
    /// keystroke back. Disabling as well shows the command as unavailable.
    /// Naming the action once keeps the shortcut and the guard from drifting apart.
    func dataGridShortcut(
        _ action: ShortcutAction,
        keyboard: KeyboardSettings,
        yieldingTo actions: MainContentCommandActions?
    ) -> some View {
        let yields = actions?.yieldsToFocusedTextInput(action, boundKey: keyboard.shortcut(for: action)) == true
        return optionalKeyboardShortcut(yields ? nil : keyboard.keyboardShortcut(for: action))
            .disabled(yields)
    }
}
