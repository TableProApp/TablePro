//
//  MainContentCommandActions+TextInputFocus.swift
//  TablePro
//
//  Tracks whether a text input owns first responder, so a data-grid menu
//  shortcut can hand a standard text-editing key back to the focused responder.
//

import AppKit
import Foundation
import os

extension MainContentCommandActions {
    /// AppKit matches a menu key equivalent before the first responder ever sees
    /// `keyDown`, and it consumes the event even when the item is disabled, so a
    /// grid shortcut that duplicates one of AppKit's own text-editing bindings has
    /// to give up its key equivalent while a text input is focused. The keystroke
    /// then reaches the responder, which runs the standard binding itself.
    func yieldsToFocusedTextInput(_ action: ShortcutAction, boundKey: BoundKey?) -> Bool {
        guard focusOwnsTextInput else { return false }
        return action.shadowsStandardTextEditingBinding(boundKey)
    }

    func updateTextInputFocusTracking() {
        if let observer = textInputFocusObserver.withLockUnchecked({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
            textInputFocusObserver.withLockUnchecked { $0 = nil }
        }
        refreshFocusOwnsTextInput()
        guard let window else { return }
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.scheduleTextInputFocusCheck()
            }
        }
        textInputFocusObserver.withLockUnchecked { $0 = observer }
    }

    /// `didUpdateNotification` fires once per event-loop pass, so the check is
    /// coalesced onto the next run loop turn and only writes on a transition.
    private func scheduleTextInputFocusCheck() {
        guard !isTextInputFocusCheckScheduled else { return }
        isTextInputFocusCheckScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isTextInputFocusCheckScheduled = false
            self.refreshFocusOwnsTextInput()
        }
    }

    /// `NSTextInputClient` covers every responder that edits text: the SQL editor
    /// (`CodeEditTextView.TextView` is `NSView`-based but conforms), an `NSTextView`
    /// field editor over a grid cell, and the sidebar filter field. It excludes
    /// `NSTableView` and `NSOutlineView`, so selecting rows or sidebar tables keeps
    /// the grid commands enabled.
    ///
    /// The transition guard carries the sync too, because `didUpdateNotification` fires
    /// on every event-loop pass and `focusOwnsTextInput` is observed. Skipping is safe:
    /// every writer resolves the yield from the key window's stored flag, so an unchanged
    /// flag cannot leave a stale menu. The key-window guard is the same argument from the
    /// other side, since a background window's focus decides nothing about the menu bar.
    private func refreshFocusOwnsTextInput() {
        let owns = window?.firstResponder is NSTextInputClient
        guard owns != focusOwnsTextInput else { return }
        focusOwnsTextInput = owns
        guard let window, window.isKeyWindow else { return }
        MainMenuBuilder.syncKeyEquivalents()
    }
}
