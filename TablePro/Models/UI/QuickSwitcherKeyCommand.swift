//
//  QuickSwitcherKeyCommand.swift
//  TablePro
//

import AppKit

/// What a key press means inside the quick switcher panel, resolved without touching AppKit state.
///
/// The panel's key handling is split across two owners: the field editor answers the commands
/// `NSTextField` sends it (arrows, Return, Escape), and everything the field editor never receives
/// arrives through a local event monitor. Command-Return is in the second group, because AppKit's
/// field editor has no command for it. Keeping the mapping here means both owners resolve a press
/// the same way and the mapping can be tested without a window.
internal enum QuickSwitcherKeyCommand: Equatable {
    case moveSelection(by: Int)
    case selectScope(index: Int)
    case commit(QuickSwitcherCommitIntent)

    private static let returnCharacters: Set<String> = ["\r", "\u{3}"]

    /// The modifiers a shortcut can be about. `.deviceIndependentFlagsMask` is not that set: it is
    /// 0xffff0000 and keeps `.capsLock`, `.numericPad` and `.function` alongside them, so an
    /// equality test against it fails for every press made with Caps Lock on, from the numeric
    /// keypad, or with Fn held. That silently disabled Command-Return, Command-1 through 5 and
    /// Control-J/K/N/P whenever Caps Lock was engaged, and made the keypad's Enter, which
    /// `returnCharacters` enumerates on purpose, unreachable at all times.
    private static let meaningfulModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]

    /// Both Option and Command mean "open somewhere new" on commit. Option-Return is what the panel
    /// has always used and what Xcode's Open Quickly uses for its alternate destination; Command
    /// is what TablePlus binds to opening an item in a new tab, and what Safari's search field
    /// binds Command-Return to. Neither is wrong, so the panel accepts both.
    internal static func commitIntent(for modifiers: NSEvent.ModifierFlags) -> QuickSwitcherCommitIntent {
        modifiers.intersection([.command, .option]).isEmpty ? .open : .openInNewWindowTab
    }

    /// Drops every flag a shortcut is not about, so a press still resolves with Caps Lock engaged,
    /// from the numeric keypad, or with Fn held.
    private static func meaningful(_ modifiers: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        modifiers.intersection(meaningfulModifiers)
    }

    /// Resolves a key press the field editor does not consume. Returns nil when the press is not
    /// the panel's to handle, so the caller passes the event on untouched.
    internal static func resolve(
        characters: String,
        modifiers rawModifiers: NSEvent.ModifierFlags,
        scopeCount: Int
    ) -> QuickSwitcherKeyCommand? {
        let modifiers = meaningful(rawModifiers)
        if modifiers == .command {
            if returnCharacters.contains(characters) {
                return .commit(.openInNewWindowTab)
            }
            if let digit = Int(characters), digit >= 1, digit <= scopeCount {
                return .selectScope(index: digit - 1)
            }
            return nil
        }

        guard modifiers == .control else { return nil }
        /// Caps Lock reaches `charactersIgnoringModifiers` as well as the modifier mask: that
        /// property drops every modifier except the ones that pick a character, and Caps Lock picks
        /// one. So with Caps Lock on AppKit delivers "J" here, and normalizing only the flags would
        /// have left these four commands as dead as they were.
        switch characters.lowercased() {
        case "j", "n": return .moveSelection(by: 1)
        case "k", "p": return .moveSelection(by: -1)
        default: return nil
        }
    }
}
