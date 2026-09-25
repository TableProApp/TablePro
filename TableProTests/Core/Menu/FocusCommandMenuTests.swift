//
//  FocusCommandMenuTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import Testing

@MainActor
private func focusSubmenu() throws -> NSMenu {
    let view = try #require(
        MainMenuBuilder.build(keyboard: KeyboardSettings())
            .items
            .first { $0.title == String(localized: "View") }?
            .submenu
    )
    return try #require(view.items.first { $0.title == String(localized: "Focus") }?.submenu)
}

@MainActor
struct FocusCommandMenuTests {
    /// The HIG asks that every function be reachable from the menu bar, and a focus command that
    /// exists only as a key combination is one a keyboard-driven user cannot discover. #2904 was
    /// filed because the sidebar list could already be reached and nothing said so.
    @Test("Every pane a keyboard user works in has a Focus command")
    func everyPaneHasAFocusCommand() throws {
        let titles = try focusSubmenu().items.map(\.title)

        #expect(titles == [
            String(localized: "Focus Sidebar Filter"),
            String(localized: "Focus Object List"),
            String(localized: "Focus Editor"),
            String(localized: "Focus Results"),
            String(localized: "Focus Inspector"),
            String(localized: "Focus Assistant"),
        ])
    }

    @Test("Each Focus command carries its own shortcut and no target")
    func eachCommandIsBoundAndUntargeted() throws {
        let items = try focusSubmenu().items

        #expect(items.count == Self.family.count)
        for (item, action) in zip(items, Self.family) {
            let expected = try #require(KeyboardSettings.defaultShortcuts[action])
            #expect(item.keyEquivalentModifierMask == expected.modifierFlags, "\(action.rawValue)")
            #expect(item.target == nil, "\(action.rawValue)")
            #expect(item.identifier == MenuItemFactory.identifier(for: action), "\(action.rawValue)")
        }
    }

    /// The family shares one modifier so a user who learns any of it has learned the rest, and the
    /// combination is the one the app already chose for Focus Sidebar Filter.
    @Test("The Focus family shares the modifier the app already uses for it")
    func theFamilySharesOneModifier() throws {
        let expected: [ShortcutAction: Character] = [
            .focusSidebarSearch: "f", .focusObjectList: "l", .focusEditor: "e",
            .focusResults: "r", .focusInspector: "i", .focusAssistant: "a",
        ]

        for action in Self.family {
            let character = try #require(expected[action])
            #expect(
                KeyboardSettings.defaultShortcuts[action]
                    == .character(character, command: true, option: true, control: true),
                "\(action.rawValue)"
            )
        }
    }

    private static let family: [ShortcutAction] = [
        .focusSidebarSearch, .focusObjectList, .focusEditor,
        .focusResults, .focusInspector, .focusAssistant,
    ]
}
