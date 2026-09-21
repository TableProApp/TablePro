//
//  ActionsMenuSpec.swift
//  TablePro
//

import AppKit

/// A submenu whose leaves are resolved when it opens rather than when the menu is built.
///
/// The resolver stays pure by naming the submenu and stopping there. Import formats come from the
/// connection's driver and the mode list from the window, and both are questions with an answer
/// that can change between two openings of the same menu; `NSMenuDelegate.menuNeedsUpdate` is where
/// they are asked, measured to fire exactly once per real open.
internal enum ActionsSubmenuKind: Equatable, Hashable, Sendable {
    case importFormats
    case mode
}

/// One command in the Actions pull-down.
///
/// Carries no target. Every entry is built with `target = nil` so AppKit routes it through the
/// responder chain and `MainSplitViewController.validateMenuItem` decides it, which is the same
/// path the menu bar already takes. Giving an entry an explicit target would hand validation to
/// `MainWindowToolbar.validateMenuItem`, whose unrecognised-action arm returns true, and ship every
/// entry enabled.
internal struct ActionsMenuEntry: Equatable {
    internal let title: String
    internal let selector: Selector
    internal let shortcut: ShortcutAction?
    /// What the command is about, for an entry that names one of several values of the same
    /// command. `setContentModeFromMenu:` needs it for both the action and the checkmark.
    internal let representedValue: String?
    internal let submenu: ActionsSubmenuKind?

    internal init(
        title: String,
        selector: Selector,
        shortcut: ShortcutAction? = nil,
        representedValue: String? = nil,
        submenu: ActionsSubmenuKind? = nil
    ) {
        self.title = title
        self.selector = selector
        self.shortcut = shortcut
        self.representedValue = representedValue
        self.submenu = submenu
    }
}

/// A run of related commands, drawn with a separator between one section and the next.
internal struct ActionsMenuSection: Equatable {
    internal let entries: [ActionsMenuEntry]

    internal init(_ entries: [ActionsMenuEntry]) {
        self.entries = entries
    }
}
