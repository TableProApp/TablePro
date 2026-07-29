//
//  EditorContextMenuRoutingTests.swift
//  TableProTests
//
//  Covers the menu resolution the #1982 fix depends on: an assigned menu wins, and a
//  text view without one keeps the standard editing items. The routing itself, that a
//  right-click below the editor reaches the result tabs rather than the editor, is
//  covered end to end by ResultTabPinUITests.
//

import AppKit
import CodeEditTextView
import Testing

@MainActor
@Suite("Editor context menu routing")
struct EditorContextMenuRoutingTests {
    @Test("A menu assigned to the text view wins over the standard editing items")
    func assignedMenuIsResolved() {
        let textView = TextView(string: "SELECT 1")
        let menu = NSMenu(title: "")
        textView.menu = menu

        #expect(textView.menu(for: Self.rightClick()) === menu)
    }

    @Test("A text view with no assigned menu keeps the standard editing items")
    func defaultEditingMenuSurvives() {
        let textView = TextView(string: "SELECT 1")

        let resolved = textView.menu(for: Self.rightClick())

        #expect(textView.menu == nil)
        #expect(resolved?.items.map(\.title) == ["Cut", "Copy", "Paste"])
    }

    private static func rightClick() -> NSEvent {
        guard let event = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: NSPoint(x: 4, y: 4),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ) else {
            fatalError("Failed to build a right-click event")
        }
        return event
    }
}
