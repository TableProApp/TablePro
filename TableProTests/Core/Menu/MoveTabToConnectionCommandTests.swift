//
//  MoveTabToConnectionCommandTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import Testing

struct MoveTabToConnectionShortcutTests {
    private static let chord = BoundKey.character("c", command: true, option: true, control: true)

    @Test("The default is Control-Option-Command-C, Switch Connection's chord plus Option")
    func defaultChord() {
        #expect(KeyboardSettings.defaultShortcuts[.moveTabToConnection] == Self.chord)
        #expect(KeyboardSettings.default.shortcut(for: .moveTabToConnection) == Self.chord)
    }

    @Test("No other default and no reserved command claims the chord")
    func chordIsUnique() {
        let owners = KeyboardSettings.defaultShortcuts.filter { $0.value == Self.chord }.map { $0.key }
        #expect(owners == [.moveTabToConnection])
        #expect(ShortcutAction.reservedConflict(for: Self.chord, context: .global) == nil)
    }

    @Test("It is listed under Connections by its own name")
    func listedUnderConnections() {
        #expect(ShortcutAction.moveTabToConnection.category == .connections)
        #expect(ShortcutAction.moveTabToConnection.context == .global)
        #expect(ShortcutAction.moveTabToConnection.displayName == String(localized: "Move Tab to Connection"))
    }
}

@MainActor
struct MoveTabToConnectionMenuTests {
    private static let selector = #selector(MainSplitViewController.moveTabToConnection(_:))

    private func databaseMenu() -> NSMenu? {
        MainMenuBuilder.build(keyboard: KeyboardSettings())
            .items.first { $0.title == String(localized: "Database") }?.submenu
    }

    @Test("The Database menu lists it directly under Switch Connection, with its shortcut")
    func sitsUnderSwitchConnection() throws {
        let items = try #require(databaseMenu()?.items)
        let switchIndex = try #require(items.firstIndex { $0.title == String(localized: "Switch Connection…") })
        let item = items[switchIndex + 1]

        #expect(item.title == String(localized: "Move Tab to Connection…"))
        #expect(item.action == Self.selector)
        #expect(item.target == nil)
        #expect(item.identifier == MenuItemFactory.identifier(for: .moveTabToConnection))
        #expect(item.keyEquivalent == "c")
        #expect(item.keyEquivalentModifierMask == [.command, .option, .control])
    }

    @Test("It follows the selected tab's move policy rather than the connection")
    func followsTheMovePolicy() {
        var context = MenuValidationContext()
        context.hasSelectedWorkspace = true
        context.isConnected = true
        #expect(MainSplitViewController.resolvedEnablement(Self.selector, context: context) == false)

        context.canMoveTabToConnection = true
        #expect(MainSplitViewController.resolvedEnablement(Self.selector, context: context) == true)

        context.isConnected = false
        #expect(
            MainSplitViewController.resolvedEnablement(Self.selector, context: context) == true,
            "The SQL text is what moves, so a lost connection does not hold it back"
        )
    }

    @Test("Agent mode shows no tab, so it dims")
    func dimsInAgentMode() {
        var context = MenuValidationContext()
        context.hasSelectedWorkspace = true
        context.isConnected = true
        context.canMoveTabToConnection = true
        context.isAgentMode = true

        #expect(MainSplitViewController.resolvedEnablement(Self.selector, context: context) == false)
    }
}
