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

        moveSelectionForContextClick(event)

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

    /// Moves the selection to the right-clicked text before the menu opens, the way `NSTextView` does.
    ///
    /// A right click inside the selection leaves it alone, so "Copy" still copies what the user can see is
    /// selected. Anywhere else it selects the word under the pointer, so a menu item that reads the selection acts
    /// on what was clicked rather than on whatever was selected beforehand.
    private func moveSelectionForContextClick(_ event: NSEvent) {
        guard isSelectable,
              let offset = layoutManager.textOffsetAtPoint(self.convert(event.locationInWindow, from: nil)) else {
            return
        }
        guard !selectionManager.textSelections.contains(where: { $0.range.contains(offset) }) else { return }

        let wordRange = findWordBoundary(at: offset)
        selectionManager.setSelectedRange(wordRange)
        selectionManager.textSelections.first?.pivot = wordRange.location
    }
}
