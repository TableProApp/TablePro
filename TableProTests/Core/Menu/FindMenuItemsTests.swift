//
//  FindMenuItemsTests.swift
//  TableProTests
//
//  Edit > Find carries the five items macOS puts there, in Apple's order and on Apple's keys. The
//  Replace half of the panel shipped behind a popup inside the panel itself, with no menu item and
//  no key equivalent, which is not where anyone looks for it.
//

import AppKit
@testable import TablePro
import Testing

@Suite("Edit > Find")
@MainActor
struct FindMenuItemsTests {
    private func findSubmenu() throws -> NSMenu {
        let menu = MainMenuBuilder.build(keyboard: KeyboardSettings())
        let edit = try #require(menu.items.first { $0.title == String(localized: "Edit") }?.submenu)
        return try #require(edit.items.first { $0.title == String(localized: "Find") }?.submenu)
    }

    @Test("The submenu lists the find commands in Apple's order")
    func submenuOrder() throws {
        let titles = try findSubmenu().items.filter { !$0.isSeparatorItem }.map(\.title)

        #expect(titles.prefix(5) == [
            String(localized: "Find…"),
            String(localized: "Find and Replace…"),
            String(localized: "Find Next"),
            String(localized: "Find Previous"),
            String(localized: "Use Selection for Find")
        ])
    }

    @Test("Find and Replace is nil-targeted on Cmd+Option+F")
    func findAndReplaceItem() throws {
        let item = try #require(try findSubmenu().items.first { $0.title == String(localized: "Find and Replace…") })

        #expect(item.action == #selector(MainSplitViewController.performFindAndReplace(_:)))
        #expect(item.target == nil)
        #expect(item.keyEquivalent == "f")
        #expect(item.keyEquivalentModifierMask == [.command, .option])
    }

    @Test("Use Selection for Find is nil-targeted on Cmd+E")
    func useSelectionItem() throws {
        let item = try #require(
            try findSubmenu().items.first { $0.title == String(localized: "Use Selection for Find") }
        )

        #expect(item.action == #selector(MainSplitViewController.useSelectionForFind(_:)))
        #expect(item.target == nil)
        #expect(item.keyEquivalent == "e")
        #expect(item.keyEquivalentModifierMask == [.command])
    }

    @Test("Both new commands dispatch by focus, so they are global rather than editor-scoped")
    func newCommandsAreGlobal() {
        #expect(ShortcutAction.findAndReplace.context == .global)
        #expect(ShortcutAction.useSelectionForFind.context == .global)
        #expect(ShortcutAction.findAndReplace.category == .editor)
        #expect(ShortcutAction.useSelectionForFind.category == .editor)
    }
}
