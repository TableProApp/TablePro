// Run, Explain and the AI actions read the caret the editor reports through its binding, so a caret moved while
// focus is elsewhere (find navigation, a jump to a result's statement) still has to reach it.

import AppKit
import SwiftUI
import TableProEditorKit
import TableProTestSupport
import TableProTextEngine
import Testing

@testable import TablePro

@MainActor
struct SQLEditorCursorPropagationTests {
    private final class Model {
        var text = "SELECT 1 AS a;\nSELECT 2 AS b;\nSELECT 3 AS zz;"
        var cursorPositions: [CursorPosition] = []
    }

    private func settle(_ window: NSWindow, until condition: () -> Bool) async throws {
        try await waitUntil {
            window.contentView?.layoutSubtreeIfNeeded()
            return condition()
        }
    }

    private func mount(_ model: Model) -> (SQLEditorController, NSWindow) {
        let editor = SQLEditorController(input: SQLEditorInput(
            text: Binding(get: { model.text }, set: { model.text = $0 }),
            cursorPositions: Binding(get: { model.cursorPositions }, set: { model.cursorPositions = $0 }),
            databaseType: .sqlite
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = editor.textViewController.view
        return (editor, window)
    }

    @Test("A caret moved while the editor is not first responder reaches the binding")
    func caretMovedWithoutFocusReachesTheBinding() async throws {
        let model = Model()
        let (editor, window) = mount(model)
        defer { editor.teardown() }
        defer { window.orderOut(nil) }
        let textView = try #require(editor.textViewController.textView)
        try await settle(window) { textView.window != nil }

        _ = window.makeFirstResponder(nil)
        try #require(window.firstResponder !== textView)

        let match = NSRange(location: 42, length: 2)
        textView.selectionManager.setSelectedRange(match)
        try await settle(window) { model.cursorPositions.map { $0.range } == [match] }

        #expect(model.cursorPositions.map { $0.range } == [match])
    }

    @Test("Typing and replacing a selection report the caret the edit left, with the edited text")
    func editCaretReachesTheBinding() async throws {
        let model = Model()
        let (editor, window) = mount(model)
        defer { editor.teardown() }
        defer { window.orderOut(nil) }
        let textView = try #require(editor.textViewController.textView)
        try await settle(window) { textView.window != nil }
        _ = window.makeFirstResponder(textView)

        textView.selectionManager.setSelectedRange(NSRange(location: 14, length: 0))
        textView.replaceCharacters(in: NSRange(location: 14, length: 0), with: "--")
        #expect(model.text.hasPrefix("SELECT 1 AS a;--"))
        #expect(model.cursorPositions.map { $0.range } == [NSRange(location: 16, length: 0)])

        textView.selectionManager.setSelectedRange(NSRange(location: 7, length: 1))
        textView.replaceCharacters(in: NSRange(location: 7, length: 1), with: "42")
        #expect(model.text.hasPrefix("SELECT 42 AS a;--"))
        #expect(model.cursorPositions.map { $0.range } == [NSRange(location: 9, length: 0)])
    }
}
