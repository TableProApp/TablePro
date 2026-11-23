// One SQL editor serves every query tab of a window, and a new tab's text kept the outgoing tab's caret, clamped.

import AppKit
import SwiftUI
@testable import TablePro
import TableProEditorKit
import TableProTextEngine
import Testing

@MainActor
struct SQLEditorTabSelectionTests {
    private final class Tabs {
        var texts: [UUID: String] = [:]

        func binding(_ id: UUID) -> Binding<String> {
            Binding(get: { self.texts[id] ?? "" }, set: { self.texts[id] = $0 })
        }
    }

    private let tabs = Tabs()
    private let histories = EditorUndoHistories()
    private let first = UUID()
    private let second = UUID()

    init() {
        tabs.texts[first] = String(repeating: "SELECT id FROM users;\n", count: 100)
        tabs.texts[second] = "SELECT 2;\nSELECT 3;"
    }

    private func input(_ tab: UUID, restoredCursorRange: NSRange? = nil) -> SQLEditorInput {
        SQLEditorInput(
            text: tabs.binding(tab),
            cursorPositions: .constant([]),
            databaseType: .sqlite,
            tabID: tab,
            undoHistories: histories,
            restoredCursorRange: restoredCursorRange
        )
    }

    private func makeEditor() -> SQLEditorController {
        let editor = SQLEditorController(input: input(first))
        let view = editor.textViewController.view
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 300)
        view.layoutSubtreeIfNeeded()
        return editor
    }

    private func selection(_ editor: SQLEditorController) -> [NSRange] {
        editor.textViewController.textView.selectionManager.textSelections.map { $0.range }
    }

    private func select(_ range: NSRange, in editor: SQLEditorController) {
        editor.textViewController.setCursorPositions([CursorPosition(range: range)])
    }

    @Test("A tab shown for the first time starts at the top, not at the last tab's caret")
    func newTabStartsAtTheTop() {
        let editor = makeEditor()
        defer { editor.teardown() }
        select(NSRange(location: 900, length: 0), in: editor)

        editor.apply(input(second))

        #expect(editor.textViewController.textView.string == tabs.texts[second])
        #expect(selection(editor) == [NSRange(location: 0, length: 0)])
    }

    @Test("Each tab gets its own selection back when it is shown again")
    func eachTabKeepsItsSelection() {
        let editor = makeEditor()
        defer { editor.teardown() }
        select(NSRange(location: 900, length: 6), in: editor)

        editor.apply(input(second))
        select(NSRange(location: 3, length: 0), in: editor)
        editor.apply(input(first))
        #expect(selection(editor) == [NSRange(location: 900, length: 6)])

        editor.apply(input(second))
        #expect(selection(editor) == [NSRange(location: 3, length: 0)])
    }

    @Test("A tab's saved caret from the last session applies when the tab is first shown")
    func savedCaretAppliesOnFirstShow() {
        let editor = makeEditor()
        defer { editor.teardown() }
        select(NSRange(location: 900, length: 0), in: editor)

        editor.apply(input(second, restoredCursorRange: NSRange(location: 10, length: 6)))

        #expect(selection(editor) == [NSRange(location: 10, length: 6)])
    }

    @Test("Each tab gets its own scroll position back")
    func eachTabKeepsItsScroll() {
        let editor = makeEditor()
        defer { editor.teardown() }
        let controller = editor.textViewController
        controller.scrollPosition = CGPoint(x: 0, y: 600)
        let scrolled = controller.scrollPosition
        #expect(scrolled.y > 0)

        editor.apply(input(second))
        #expect(controller.scrollPosition.y < 1)

        editor.apply(input(first))
        #expect(controller.scrollPosition.y == scrolled.y)
    }
}
