//
//  CommandActionsFocusGateTests.swift
//  TableProTests
//
//  Pins the focus gate that stops a data-grid menu shortcut from claiming a
//  keystroke the focused text input already owns.
//

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

        var selectedTables: Set<TableInfo> = []
        var pendingTruncates: Set<String> = []
        var pendingDeletes: Set<String> = []
        var tableOperationOptions: [String: TableOperationOptions] = [:]

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
}
