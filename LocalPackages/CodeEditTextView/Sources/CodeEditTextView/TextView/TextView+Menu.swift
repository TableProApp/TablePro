//
//  TextView+Menu.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 8/21/23.
//

import AppKit

extension TextView {
    /// Returns the menu assigned to this text view, falling back to the standard editing items.
    /// Resolution runs through `NSView.menu(for:)`, so AppKit's own hit testing decides which view
    /// owns the click rather than a view guessing from event coordinates.
    override public func menu(for event: NSEvent) -> NSMenu? {
        guard event.type == .rightMouseDown else { return nil }

        if let assignedMenu = super.menu(for: event) {
            return assignedMenu
        }

        let menu = NSMenu()
        menu.items = [
            NSMenuItem(title: "Cut", action: #selector(cut(_:)), keyEquivalent: "x"),
            NSMenuItem(title: "Copy", action: #selector(copy(_:)), keyEquivalent: "c"),
            NSMenuItem(title: "Paste", action: #selector(paste(_:)), keyEquivalent: "v")
        ]

        return menu
    }
}
