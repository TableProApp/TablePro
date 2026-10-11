//
//  MenuPlaceholder.swift
//  TablePro
//

import AppKit

/// The one row a delegate-filled list shows when it has nothing to list.
///
/// A menu with no items opens as a sliver with no text, which reads as a broken command, and the row
/// that opens it cannot be dimmed through the responder chain because AppKit gives a submenu's row
/// its own action. So the list says why it is empty instead.
///
/// One place rather than one per delegate: four lists are filled on open, and a fifth would otherwise
/// arrive with a fourth copy of the same disabled row or with none at all.
@MainActor
internal enum MenuPlaceholder {
    internal static func item() -> NSMenuItem {
        let item = NSMenuItem(title: String(localized: "None Available"), action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}
