//
//  ServerToolsCommandTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import Testing

struct ServerToolsShortcutTests {
    @Test(
        "Each chord belongs to its command alone and shadows no reserved command",
        arguments: [
            (ShortcutAction.showServerDashboard, BoundKey.character("d", command: true, shift: true, option: true)),
            (ShortcutAction.showQueryInsights, BoundKey.character("i", command: true, shift: true, option: true))
        ]
    )
    func chordIsUnique(action: ShortcutAction, chord: BoundKey) {
        #expect(KeyboardSettings.defaultShortcuts[action] == chord)
        let owners = KeyboardSettings.defaultShortcuts.filter { $0.value == chord }.map(\.key)
        #expect(owners == [action])
        #expect(ShortcutAction.reservedConflict(for: chord, context: action.context) == nil)
    }

    @Test("Both are listed under Connections by the names the Database menu uses")
    func listedUnderConnections() {
        #expect(ShortcutAction.showServerDashboard.category == .connections)
        #expect(ShortcutAction.showQueryInsights.category == .connections)
        #expect(ShortcutAction.showServerDashboard.context == .global)
        #expect(ShortcutAction.showQueryInsights.context == .global)
        #expect(ShortcutAction.showServerDashboard.displayName == String(localized: "Server Dashboard"))
        #expect(ShortcutAction.showQueryInsights.displayName == String(localized: "Query Insights"))
    }
}

@MainActor
struct ServerToolsMenuTests {
    private func databaseItem(_ title: String) -> NSMenuItem? {
        MainMenuBuilder.build(keyboard: KeyboardSettings()).bar
            .items.first { $0.title == String(localized: "Database") }?.submenu?
            .items.first { $0.title == title }
    }

    @Test("Database > Server Dashboard carries its shortcut")
    func serverDashboardItem() throws {
        let item = try #require(databaseItem(String(localized: "Server Dashboard")))
        #expect(item.action == #selector(MainSplitViewController.showServerDashboard(_:)))
        #expect(item.identifier == MenuItemFactory.identifier(for: .showServerDashboard))
        #expect(item.keyEquivalent == "d")
        #expect(item.keyEquivalentModifierMask == [.command, .shift, .option])
    }

    @Test("Database > Query Insights carries its shortcut")
    func queryInsightsItem() throws {
        let item = try #require(databaseItem(String(localized: "Query Insights")))
        #expect(item.action == #selector(MainSplitViewController.showQueryInsights(_:)))
        #expect(item.identifier == MenuItemFactory.identifier(for: .showQueryInsights))
        #expect(item.keyEquivalent == "i")
        #expect(item.keyEquivalentModifierMask == [.command, .shift, .option])
    }

    @Test("A cleared binding leaves the item without a key equivalent")
    func clearedBindingLeavesNoKey() throws {
        var keyboard = KeyboardSettings()
        keyboard.clearShortcut(for: .showServerDashboard)
        let item = try #require(
            MainMenuBuilder.build(keyboard: keyboard).bar
                .items.first { $0.title == String(localized: "Database") }?.submenu?
                .items.first { $0.title == String(localized: "Server Dashboard") }
        )
        #expect(item.keyEquivalent.isEmpty)
    }
}
