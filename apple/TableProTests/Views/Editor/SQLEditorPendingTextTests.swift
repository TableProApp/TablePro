// Over 500,000 units the editor writes its text to the tab 150 ms after the last key, so a tab switch, a teardown,
// a close or a script inside that window dropped the last keys or read the tab without them.

import AppKit
import SwiftUI
import TableProEditorKit
import TableProTestSupport
import TableProTextEngine
import Testing

@testable import TablePro

@MainActor
private enum LargeTabEditor {
    static let text = String(repeating: "a", count: 500_001)

    static func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }

    // Bound to the tab by id, as the query tab binds it, and in a window, so the router can reach it.
    static func mount(on coordinator: MainContentCoordinator, tabId: UUID) async throws -> (SQLEditorController, NSWindow) {
        let manager = coordinator.tabManager
        let editor = SQLEditorController(input: SQLEditorInput(
            text: Binding(
                get: { manager.tabs.first { $0.id == tabId }?.content.query ?? "" },
                set: { value in manager.mutate(tabId: tabId) { $0.content.query = value } }
            ),
            cursorPositions: .constant([]),
            databaseType: coordinator.connection.type,
            connectionId: coordinator.connectionId,
            tabID: tabId,
            claimFocusOnAppear: true
        ))
        let window = makeWindow()
        window.contentView = editor.textViewController.view
        coordinator.contentWindow = window
        try await waitUntil {
            window.contentView?.layoutSubtreeIfNeeded()
            return !editor.coordinator.pendingFocusClaim
        }
        return (editor, window)
    }

    static func typeAtStart(_ text: String, in editor: SQLEditorController, window: NSWindow) async throws {
        let textView = try #require(editor.textViewController.textView)
        try await waitUntil {
            window.contentView?.layoutSubtreeIfNeeded()
            return textView.window != nil
        }
        _ = window.makeFirstResponder(textView)
        textView.selectionManager.setSelectedRange(NSRange(location: 0, length: 0))
        textView.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
    }

    static func addFileTab(to coordinator: MainContentCoordinator, databaseName: String = "") throws -> UUID {
        let manager = coordinator.tabManager
        manager.addTab(
            initialQuery: text,
            title: "Large",
            databaseName: databaseName,
            sourceFileURL: URL(fileURLWithPath: "/private/tmp/sql-editor-pending-text.sql")
        )
        let tabId = try #require(manager.selectedTabId)
        try #require(!coordinator.hasUnsavedWork(forTab: tabId))
        return tabId
    }

    static func query(ofTab tabId: UUID, in coordinator: MainContentCoordinator) -> String? {
        coordinator.tabManager.tabs.first { $0.id == tabId }?.content.query
    }
}

@MainActor
struct SQLEditorPendingTextTests {
    private final class Tabs {
        var texts: [UUID: String] = [:]

        func binding(_ id: UUID) -> Binding<String> {
            Binding(get: { self.texts[id] ?? "" }, set: { self.texts[id] = $0 })
        }
    }

    private func input(_ tabs: Tabs, tab id: UUID) -> SQLEditorInput {
        SQLEditorInput(text: tabs.binding(id), cursorPositions: .constant([]), databaseType: .sqlite, tabID: id)
    }

    @Test("A tab switch right after typing keeps the keys in the tab they were typed in")
    func switchKeepsTheLastKeys() async throws {
        let tabs = Tabs()
        let first = UUID()
        let second = UUID()
        tabs.texts[first] = LargeTabEditor.text
        tabs.texts[second] = "SELECT 2"
        let editor = SQLEditorController(input: input(tabs, tab: first))
        let window = LargeTabEditor.makeWindow()
        window.contentView = editor.textViewController.view
        defer { editor.teardown() }
        defer { window.orderOut(nil) }
        try await LargeTabEditor.typeAtStart("x", in: editor, window: window)
        try #require(tabs.texts[first] == LargeTabEditor.text)

        editor.apply(input(tabs, tab: second))

        try await waitUntil { tabs.texts[first] == "x" + LargeTabEditor.text }
        #expect(editor.textViewController.textView.string == "SELECT 2")
        #expect(tabs.texts[second] == "SELECT 2")
    }

    @Test("Closing the editor right after typing still writes the keys to the tab")
    func teardownKeepsTheLastKeys() async throws {
        let tabs = Tabs()
        let tab = UUID()
        tabs.texts[tab] = LargeTabEditor.text
        var editor: SQLEditorController? = SQLEditorController(input: input(tabs, tab: tab))
        let window = LargeTabEditor.makeWindow()
        window.contentView = editor?.textViewController.view
        defer { window.orderOut(nil) }
        try await LargeTabEditor.typeAtStart("x", in: try #require(editor), window: window)
        try #require(tabs.texts[tab] == LargeTabEditor.text)

        editor?.teardown()
        window.contentView = nil
        editor = nil

        try await waitUntil { tabs.texts[tab] == "x" + LargeTabEditor.text }
    }

    @Test("Closing a clean file tab right after typing asks to save it")
    func closeRightAfterTypingAsks() async throws {
        let connection = TestFixtures.makeConnection(database: "db_a")
        let coordinator = SessionStateFactory.create(connection: connection, payload: nil).coordinator
        defer { coordinator.teardown() }
        let tabId = try LargeTabEditor.addFileTab(to: coordinator)
        let (editor, window) = try await LargeTabEditor.mount(on: coordinator, tabId: tabId)
        defer { editor.teardown() }
        defer { window.orderOut(nil) }
        try await LargeTabEditor.typeAtStart("x", in: editor, window: window)
        try #require(LargeTabEditor.query(ofTab: tabId, in: coordinator) == LargeTabEditor.text)

        var selectedTables: Set<DatabaseTreeTableRef> = []
        var pendingTruncates: Set<DatabaseTreeTableRef> = []
        var pendingDeletes: Set<DatabaseTreeTableRef> = []
        var tableOperationOptions: [DatabaseTreeTableRef: TableOperationOptions] = [:]
        let actions = MainContentCommandActions(
            coordinator: coordinator,
            connection: connection,
            selectedTables: Binding(get: { selectedTables }, set: { selectedTables = $0 }),
            pendingTruncates: Binding(get: { pendingTruncates }, set: { pendingTruncates = $0 }),
            pendingDeletes: Binding(get: { pendingDeletes }, set: { pendingDeletes = $0 }),
            tableOperationOptions: Binding(get: { tableOperationOptions }, set: { tableOperationOptions = $0 }),
            trailingPaneState: TrailingPaneState()
        )
        actions.window = window
        var prompts = 0
        actions.confirmSaveChanges = { _, _ in
            prompts += 1
            return .cancel
        }

        await actions.closeTabAwaiting(id: tabId)

        #expect(prompts == 1)
        #expect(LargeTabEditor.query(ofTab: tabId, in: coordinator) == "x" + LargeTabEditor.text)
    }

    @Test("Closing a rail entry right after typing reads its tabs with the last keys")
    func railEntryCloseReadsTheLastKeys() async throws {
        let connection = TestFixtures.makeConnection(database: "db_a")
        let coordinator = SessionStateFactory.create(connection: connection, payload: nil).coordinator
        defer { coordinator.teardown() }
        let tabId = try LargeTabEditor.addFileTab(to: coordinator, databaseName: "db_a")
        let (editor, window) = try await LargeTabEditor.mount(on: coordinator, tabId: tabId)
        defer { editor.teardown() }
        defer { window.orderOut(nil) }
        try await LargeTabEditor.typeAtStart("x", in: editor, window: window)
        try #require(LargeTabEditor.query(ofTab: tabId, in: coordinator) == LargeTabEditor.text)

        let victims = WorkspaceCloseAction.committedTabs(in: "db_a", across: [coordinator])

        let victim = try #require(victims.first { $0.id == tabId })
        #expect(victim.content.query == "x" + LargeTabEditor.text)
        #expect(coordinator.hasUnsavedWork(in: victim))
    }
}

extension GlobalStateSuites {
    @MainActor
    struct ScriptingPendingTextTests {
        @Test("A script reads a large tab's text with the keys typed a moment ago")
        func scriptReadsTheLastKeys() async throws {
            let connection = TestFixtures.makeConnection(database: "db_a")
            let saved = ConnectionStorage.shared.loadConnections()
            ConnectionStorage.shared.saveConnections(saved + [connection])
            defer { ConnectionStorage.shared.saveConnections(saved) }
            let coordinator = SessionStateFactory.create(connection: connection, payload: nil).coordinator
            defer { coordinator.teardown() }
            let tabId = try LargeTabEditor.addFileTab(to: coordinator)
            let (editor, window) = try await LargeTabEditor.mount(on: coordinator, tabId: tabId)
            defer { editor.teardown() }
            defer { window.orderOut(nil) }
            try await LargeTabEditor.typeAtStart("x", in: editor, window: window)
            try #require(LargeTabEditor.query(ofTab: tabId, in: coordinator) == LargeTabEditor.text)

            let query = ScriptingSnapshot.query(ofTab: tabId, connectionId: connection.id)

            #expect(query == "x" + LargeTabEditor.text)
        }
    }
}
