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

/// One row in the Actions pull-down: a command, or a submenu's own row.
///
/// A command carries no target. Every one is built with `target = nil` so AppKit routes it through
/// the responder chain and `MainSplitViewController.validateMenuItem` decides it, which is the same
/// path the menu bar already takes. Giving a command an explicit target would hand validation to
/// `MainWindowToolbar.validateMenuItem`, whose unrecognised-action arm returns true, and ship every
/// entry enabled.
internal struct ActionsMenuEntry: Equatable {
    /// Two roles rather than optional fields, so a submenu's row cannot declare a selector or a
    /// shortcut it would never draw. Measured, assigning `submenu` replaces the row's action with
    /// `submenuAction:` and its target with the submenu, and AppKit ignores a key equivalent on an
    /// item that owns a submenu, so both would be promises the menu does not keep.
    internal enum Role: Equatable {
        case command(Selector, shortcut: ShortcutAction?)
        case submenu(ActionsSubmenuKind)
    }

    internal let title: String
    internal let role: Role

    internal init(title: String, selector: Selector, shortcut: ShortcutAction? = nil) {
        self.title = title
        self.role = .command(selector, shortcut: shortcut)
    }

    internal init(title: String, submenu: ActionsSubmenuKind) {
        self.title = title
        self.role = .submenu(submenu)
    }

    /// Nil for a submenu's row.
    internal var selector: Selector? {
        guard case let .command(selector, _) = role else { return nil }
        return selector
    }

    /// Nil for a submenu's row, and for a command with no chord.
    internal var shortcut: ShortcutAction? {
        guard case let .command(_, shortcut) = role else { return nil }
        return shortcut
    }

    /// Nil for a command.
    internal var submenu: ActionsSubmenuKind? {
        guard case let .submenu(kind) = role else { return nil }
        return kind
    }
}

/// A run of related commands, drawn with a separator between one section and the next.
internal struct ActionsMenuSection: Equatable {
    internal let entries: [ActionsMenuEntry]

    internal init(_ entries: [ActionsMenuEntry]) {
        self.entries = entries
    }
}
