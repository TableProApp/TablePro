//
//  CommandActionsFocusGateTests.swift
//  TableProTests
//
//  Pins the focus gate that stops a data-grid menu shortcut from claiming a
//  keystroke the focused text input already owns.
//

import AppKit
import Foundation
import SwiftUI
@testable import TablePro
import Testing

@MainActor @Suite("CommandActions focus gate")
struct CommandActionsFocusGateTests {
    private func makeSUT() -> MainContentCommandActions {
        let connection = TestFixtures.makeConnection()
        let state = SessionStateFactory.create(connection: connection, payload: nil)
        let coordinator = state.coordinator

        var selectedTables: Set<DatabaseTreeTableRef> = []
        var pendingTruncates: Set<DatabaseTreeTableRef> = []
        var pendingDeletes: Set<DatabaseTreeTableRef> = []
        var tableOperationOptions: [DatabaseTreeTableRef: TableOperationOptions] = [:]

        return MainContentCommandActions(
            coordinator: coordinator,
            connection: connection,
            selectionState: coordinator.selectionState,
            selectedTables: Binding(get: { selectedTables }, set: { selectedTables = $0 }),
            pendingTruncates: Binding(get: { pendingTruncates }, set: { pendingTruncates = $0 }),
            pendingDeletes: Binding(get: { pendingDeletes }, set: { pendingDeletes = $0 }),
            tableOperationOptions: Binding(
                get: { tableOperationOptions },
                set: { tableOperationOptions = $0 }
            ),
            rightPanelState: RightPanelState()
        )
    }

    @Test("A fresh instance reports no text input focus")
    func defaultsToNoTextInputFocus() {
        #expect(!makeSUT().focusOwnsTextInput)
    }

    @Test("Delete keeps Cmd+Delete while the grid holds focus")
    func deleteKeepsShortcutWithoutTextFocus() {
        let actions = makeSUT()
        actions.focusOwnsTextInput = false

        #expect(!actions.yieldsToFocusedTextInput(.delete, boundKey: .special(.delete, command: true)))
    }

    @Test("Delete yields Cmd+Delete to a focused text input")
    func deleteYieldsToTextFocus() {
        let actions = makeSUT()
        actions.focusOwnsTextInput = true

        #expect(actions.yieldsToFocusedTextInput(.delete, boundKey: .special(.delete, command: true)))
    }

    @Test("Truncate Table yields Option+Delete to a focused text input")
    func truncateYieldsToTextFocus() {
        let actions = makeSUT()
        actions.focusOwnsTextInput = true

        #expect(actions.yieldsToFocusedTextInput(.truncateTable, boundKey: .special(.delete, option: true)))
    }

    @Test("A grid action with no colliding binding keeps its shortcut under text focus")
    func nonCollidingGridActionKeepsShortcut() {
        let actions = makeSUT()
        actions.focusOwnsTextInput = true

        #expect(
            !actions.yieldsToFocusedTextInput(.addRow, boundKey: .character("n", command: true, shift: true))
        )
    }

    @Test("An editor action keeps its shortcut under text focus")
    func editorActionKeepsShortcut() {
        let actions = makeSUT()
        actions.focusOwnsTextInput = true

        #expect(!actions.yieldsToFocusedTextInput(.executeQuery, boundKey: .special(.delete, command: true)))
    }

    @Test("An unbound grid action yields nothing")
    func unboundGridActionYieldsNothing() {
        let actions = makeSUT()
        actions.focusOwnsTextInput = true

        #expect(!actions.yieldsToFocusedTextInput(.delete, boundKey: nil))
    }

    // MARK: - Menu Key Equivalent Ownership

    private static let syncedActions: [ShortcutAction] = [.delete, .truncateTable, .addRow]

    private func makeMenuBar(keyboard: KeyboardSettings) -> NSMenu {
        let items = Self.syncedActions.map {
            MenuItemFactory.item($0.rawValue, action: nil, shortcut: $0, keyboard: keyboard)
        }
        let menu = NSMenu()
        menu.addItem(MenuItemFactory.menu("Database", items: items))
        return menu
    }

    private struct MenuEquivalent: Equatable {
        static let cleared = MenuEquivalent(characters: "", modifiers: [])

        let characters: String
        let modifiers: NSEvent.ModifierFlags
    }

    private func equivalents(in menu: NSMenu) -> [ShortcutAction: MenuEquivalent] {
        var found: [ShortcutAction: MenuEquivalent] = [:]
        for container in menu.items {
            for item in container.submenu?.items ?? [] {
                guard let raw = item.identifier?.rawValue,
                      raw.hasPrefix("shortcut."),
                      let action = ShortcutAction(rawValue: String(raw.dropFirst("shortcut.".count)))
                else { continue }
                found[action] = MenuEquivalent(
                    characters: item.keyEquivalent,
                    modifiers: item.keyEquivalentModifierMask
                )
            }
        }
        return found
    }

    private func bound(_ action: ShortcutAction, _ keyboard: KeyboardSettings) -> MenuEquivalent {
        guard let resolved = keyboard.menuKeyEquivalent(for: action) else { return .cleared }
        return MenuEquivalent(characters: resolved.characters, modifiers: resolved.modifiers)
    }

    /// The restore assertions only mean something when the defaults actually bind these
    /// actions, which a runner without a keyboard layout could break silently.
    private func expectSyncedActionsAreBound(_ keyboard: KeyboardSettings) {
        #expect(bound(.delete, keyboard) != MenuEquivalent.cleared)
        #expect(bound(.truncateTable, keyboard) != MenuEquivalent.cleared)
        #expect(bound(.addRow, keyboard) != MenuEquivalent.cleared)
    }

    @Test("A focused text input strips only the grid shortcuts it shadows")
    func textFocusStripsShadowedEquivalents() {
        let keyboard = KeyboardSettings.default
        let menu = makeMenuBar(keyboard: keyboard)
        let actions = makeSUT()
        actions.focusOwnsTextInput = true
        expectSyncedActionsAreBound(keyboard)

        MainMenuBuilder.syncKeyEquivalents(keyboard: keyboard, actions: actions, to: menu)

        let stripped = equivalents(in: menu)
        #expect(stripped[.delete] == MenuEquivalent.cleared)
        #expect(stripped[.truncateTable] == MenuEquivalent.cleared)
        #expect(stripped[.addRow] == bound(.addRow, keyboard))
    }

    @Test("Becoming key with no text focus restores every stripped equivalent")
    func keyWindowWithoutTextFocusRestoresEquivalents() {
        let keyboard = KeyboardSettings.default
        let menu = makeMenuBar(keyboard: keyboard)
        let focused = makeSUT()
        focused.focusOwnsTextInput = true
        expectSyncedActionsAreBound(keyboard)
        MainMenuBuilder.syncKeyEquivalents(keyboard: keyboard, actions: focused, to: menu)
        #expect(equivalents(in: menu)[.delete] == MenuEquivalent.cleared)

        let incoming = makeSUT()
        incoming.focusOwnsTextInput = false
        MainMenuBuilder.syncKeyEquivalents(keyboard: keyboard, actions: incoming, to: menu)

        let restored = equivalents(in: menu)
        for action in Self.syncedActions {
            #expect(restored[action] == bound(action, keyboard))
        }
    }

    @Test("A key window that owns no command actions restores every stripped equivalent")
    func keyWindowWithoutCommandActionsRestoresEquivalents() {
        let keyboard = KeyboardSettings.default
        let menu = makeMenuBar(keyboard: keyboard)
        let focused = makeSUT()
        focused.focusOwnsTextInput = true
        expectSyncedActionsAreBound(keyboard)
        MainMenuBuilder.syncKeyEquivalents(keyboard: keyboard, actions: focused, to: menu)
        #expect(equivalents(in: menu)[.delete] == MenuEquivalent.cleared)

        MainMenuBuilder.syncKeyEquivalents(keyboard: keyboard, actions: nil, to: menu)

        let restored = equivalents(in: menu)
        for action in Self.syncedActions {
            #expect(restored[action] == bound(action, keyboard))
        }
    }

    @Test("Re-applying the same inputs never resurrects an equivalent a text input owns")
    func repeatedSyncKeepsYield() {
        let keyboard = KeyboardSettings.default
        let menu = makeMenuBar(keyboard: keyboard)
        let actions = makeSUT()
        actions.focusOwnsTextInput = true

        MainMenuBuilder.syncKeyEquivalents(keyboard: keyboard, actions: actions, to: menu)
        let first = equivalents(in: menu)
        MainMenuBuilder.syncKeyEquivalents(keyboard: keyboard, actions: actions, to: menu)

        #expect(equivalents(in: menu) == first)
        #expect(first[.delete] == MenuEquivalent.cleared)
        #expect(first[.truncateTable] == MenuEquivalent.cleared)
    }
}
