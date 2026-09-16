//
//  SuggestionKeyPolicy.swift
//  TableProEditorKit
//
//  Which keys the completion panel owns while it is showing. The panel is consulted from a local
//  key-down monitor, and a monitor that returns nil stops the event before the main menu sees it,
//  so a key this answers for is a key no menu item can run.
//

import AppKit
import Carbon.HIToolbox

internal enum SuggestionKeyOutcome: Equatable {
    case dismiss
    case moveSelection(Int)
    case applySelection
    case passThrough
}

internal enum SuggestionKeyPolicy {
    /// The panel owns a bare key it can act on, and nothing else.
    ///
    /// A chord carrying a modifier belongs to whoever bound it: measured, a local key-down monitor
    /// is called before the main menu's key equivalent and consuming the event stops the menu item
    /// firing at all, so answering for `Cmd+Return` took Execute Query away from the editor.
    ///
    /// With nothing selected there is nothing to apply, and the panel that renders "No Completions"
    /// used to answer for every one of these keys and do nothing with them, which left the list the
    /// only way out being `Escape`. Dismissing is what the user was reaching for.
    static func outcome(
        forKeyCode keyCode: Int,
        modifiers: NSEvent.ModifierFlags,
        hasSelection: Bool
    ) -> SuggestionKeyOutcome {
        guard modifiers.intersection(.deviceIndependentFlagsMask).subtracting(.function).isEmpty else {
            return .passThrough
        }

        switch keyCode {
        case kVK_Escape:
            return .dismiss
        case kVK_DownArrow:
            return hasSelection ? .moveSelection(1) : .dismiss
        case kVK_UpArrow:
            return hasSelection ? .moveSelection(-1) : .dismiss
        case kVK_Return, kVK_Tab:
            return hasSelection ? .applySelection : .dismiss
        default:
            return .passThrough
        }
    }
}
