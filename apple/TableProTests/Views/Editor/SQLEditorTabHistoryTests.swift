// One SQL editor serves every query tab of a window. Handing it another tab's text, or text a command wrote to the
// tab (Clear Query, a history entry, an AI suggestion), went through `setText`, which cleared the undo history.

import AppKit
import SwiftUI
import TableProEditorKit
import TableProTestSupport
import TableProTextEngine
import Testing

@testable import TablePro

@MainActor
struct SQLEditorTabHistoryTests {
    private final class Tabs {
        var texts: [UUID: String] = [:]

        func binding(_ id: UUID) -> Binding<String> {
            Binding(get: { self.texts[id] ?? "" }, set: { self.texts[id] = $0 })
        }
    }

    private func input(_ tabs: Tabs, tab id: UUID, histories: EditorUndoHistories) -> SQLEditorInput {
        SQLEditorInput(
            text: tabs.binding(id),
            cursorPositions: .constant([]),
            databaseType: .sqlite,
            tabID: id,
            undoHistories: histories
        )
    }

    // The tab's next render after the edit wrote its text, as the query tab runs it.
    private func type(_ string: String, at location: Int, in editor: SQLEditorController, input: SQLEditorInput) {
        editor.textViewController.textView.replaceCharacters(in: NSRange(location: location, length: 0), with: string)
        editor.apply(input)
    }

    @Test("Undo after switching away and back takes back the tab's last edit")
    func undoSurvivesATabSwitch() throws {
        let tabs = Tabs()
        let histories = EditorUndoHistories()
        let first = UUID()
        let second = UUID()
        tabs.texts[first] = "SELECT 1"
        tabs.texts[second] = "SELECT 2"
        let editor = SQLEditorController(input: input(tabs, tab: first, histories: histories))
        defer { editor.teardown() }
        let textView = try #require(editor.textViewController.textView)
        type("0", at: 8, in: editor, input: input(tabs, tab: first, histories: histories))
        try #require(tabs.texts[first] == "SELECT 10")

        editor.apply(input(tabs, tab: second, histories: histories))
        #expect(textView.string == "SELECT 2")
        #expect(textView.undoManager?.canUndo == false)

        editor.apply(input(tabs, tab: first, histories: histories))
        #expect(textView.string == "SELECT 10")
        textView.undoManager?.undo()
        #expect(textView.string == "SELECT 1")
        #expect(tabs.texts[first] == "SELECT 1")
    }

    @Test("Text a command writes to the tab, as Clear Query does, can be undone")
    func clearQueryCanBeUndone() throws {
        let tabs = Tabs()
        let histories = EditorUndoHistories()
        let tab = UUID()
        tabs.texts[tab] = "SELECT 1"
        let editor = SQLEditorController(input: input(tabs, tab: tab, histories: histories))
        defer { editor.teardown() }
        let textView = try #require(editor.textViewController.textView)

        tabs.texts[tab] = ""
        editor.apply(input(tabs, tab: tab, histories: histories))
        #expect(textView.string == "")

        textView.undoManager?.undo()
        #expect(textView.string == "SELECT 1")
        #expect(tabs.texts[tab] == "SELECT 1")
    }

    @Test("A tab whose text changed while it was away comes back with no history")
    func changedTabTextDropsItsHistory() throws {
        let tabs = Tabs()
        let histories = EditorUndoHistories()
        let first = UUID()
        let second = UUID()
        tabs.texts[first] = "SELECT 1"
        tabs.texts[second] = "SELECT 2"
        let editor = SQLEditorController(input: input(tabs, tab: first, histories: histories))
        defer { editor.teardown() }
        let textView = try #require(editor.textViewController.textView)
        type("0", at: 8, in: editor, input: input(tabs, tab: first, histories: histories))

        editor.apply(input(tabs, tab: second, histories: histories))
        tabs.texts[first] = "SELECT 3"
        editor.apply(input(tabs, tab: first, histories: histories))

        #expect(textView.string == "SELECT 3")
        #expect(textView.undoManager?.canUndo == false)
    }

    @Test("A new editor for the tab, as after a table tab was shown, gets the tab's history back")
    func historyOutlivesTheEditor() throws {
        let tabs = Tabs()
        let histories = EditorUndoHistories()
        let tab = UUID()
        tabs.texts[tab] = "SELECT 1"
        let editor = SQLEditorController(input: input(tabs, tab: tab, histories: histories))
        type("0", at: 8, in: editor, input: input(tabs, tab: tab, histories: histories))
        editor.teardown()

        let next = SQLEditorController(input: input(tabs, tab: tab, histories: histories))
        defer { next.teardown() }
        let textView = try #require(next.textViewController.textView)
        #expect(textView.string == "SELECT 10")
        textView.undoManager?.undo()

        #expect(textView.string == "SELECT 1")
    }

    @Test("Vim marks restored before Vim is installed wait for it, and a replaced document drops them")
    func pendingVimMarksFollowTheDocument() {
        let coordinator = SQLEditorCoordinator(diagnosticsClock: ManualClock())
        coordinator.databaseType = .mysql
        let controller = EditorControllerFixture.make(string: "SELECT 1", coordinators: [coordinator])
        defer { coordinator.destroy() }
        var marks = VimDocumentMarks()
        marks.marks["a"] = 3

        coordinator.restoreVimDocumentMarks(marks)
        #expect(coordinator.vimDocumentMarks?.marks["a"] == 3)

        controller.setText("SELECT 2")
        #expect(coordinator.vimDocumentMarks == nil)
    }
}
