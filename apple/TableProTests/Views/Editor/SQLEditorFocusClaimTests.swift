// Query tabs share one editor, so a new tab's focus claim reaches an editor that is already in the window.

import AppKit
import SwiftUI
import TableProEditorKit
import TableProTestSupport
import Testing

@testable import TablePro

@MainActor
struct SQLEditorFocusClaimTests {
    private final class Model {
        var text = "SELECT 1;"
        var cursorPositions: [CursorPosition] = []
    }

    private final class FocusableView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    private func input(_ model: Model, tabID: UUID, claimFocus: Bool) -> SQLEditorInput {
        var input = SQLEditorInput(
            text: Binding(get: { model.text }, set: { model.text = $0 }),
            cursorPositions: Binding(get: { model.cursorPositions }, set: { model.cursorPositions = $0 }),
            databaseType: .sqlite,
            tabID: tabID
        )
        input.claimFocusOnAppear = claimFocus
        return input
    }

    private func mount(_ editor: SQLEditorController) -> (NSWindow, FocusableView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let sidebar = FocusableView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
        let editorView = editor.textViewController.view
        editorView.frame = NSRect(x: 200, y: 0, width: 400, height: 400)
        content.addSubview(sidebar)
        content.addSubview(editorView)
        window.contentView = content
        return (window, sidebar)
    }

    private func showEditorWithFocusElsewhere(_ model: Model) async throws -> (SQLEditorController, NSWindow, NSView) {
        let editor = SQLEditorController(input: input(model, tabID: UUID(), claimFocus: false))
        let (window, sidebar) = mount(editor)
        let textView = try #require(editor.textViewController.textView)
        try await waitUntil { window.firstResponder === textView }
        _ = window.makeFirstResponder(sidebar)
        try #require(window.firstResponder === sidebar)
        return (editor, window, textView)
    }

    @Test("A new tab that claims focus takes it from the view holding it, in an editor already shown")
    func claimTakesFocusInAShownEditor() async throws {
        let model = Model()
        let (editor, window, textView) = try await showEditorWithFocusElsewhere(model)
        defer { editor.teardown() }
        defer { window.orderOut(nil) }

        editor.apply(input(model, tabID: UUID(), claimFocus: true))

        #expect(window.firstResponder === textView)
    }

    @Test("A tab shown without a claim leaves focus where it is")
    func noClaimKeepsFocus() async throws {
        let model = Model()
        let (editor, window, _) = try await showEditorWithFocusElsewhere(model)
        defer { editor.teardown() }
        defer { window.orderOut(nil) }
        let holder = window.firstResponder

        editor.apply(input(model, tabID: UUID(), claimFocus: false))

        #expect(window.firstResponder === holder)
    }
}
