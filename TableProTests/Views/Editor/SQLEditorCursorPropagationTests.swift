//
//  SQLEditorCursorPropagationTests.swift
//  TableProTests
//
//  Run, Explain and the AI actions read the caret the editor reports through its binding, so a caret moved while
//  focus is elsewhere (find navigation, a jump to a result's statement) still has to reach it.
//

import AppKit
import Combine
import SwiftUI
import TableProEditorKit
import TableProTextEngine
import Testing

@testable import TablePro

@MainActor
struct SQLEditorCursorPropagationTests {
    private final class Model: ObservableObject {
        @Published var text = "SELECT 1 AS a;\nSELECT 2 AS b;\nSELECT 3 AS zz;"
        @Published var cursorPositions: [CursorPosition] = []
        @Published var vimMode: VimMode = .normal
    }

    private struct Host: View {
        @ObservedObject var model: Model

        var body: some View {
            SQLEditorView(
                text: $model.text,
                cursorPositions: $model.cursorPositions,
                databaseType: .sqlite,
                vimMode: $model.vimMode
            )
        }
    }

    private func settle(_ window: NSWindow) {
        for _ in 0 ..< 10 {
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
    }

    private func textView(in view: NSView?) -> TextView? {
        guard let view else { return nil }
        if let textView = view as? TextView { return textView }
        for subview in view.subviews {
            if let found = textView(in: subview) { return found }
        }
        return nil
    }

    @Test("A caret moved while the editor is not first responder reaches the binding")
    func caretMovedWithoutFocusReachesTheBinding() throws {
        let model = Model()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Host(model: model))
        defer { window.orderOut(nil) }
        settle(window)

        let editor = try #require(textView(in: window.contentView))
        _ = window.makeFirstResponder(nil)
        try #require(window.firstResponder !== editor)

        let match = NSRange(location: 42, length: 2)
        editor.selectionManager.setSelectedRange(match)
        settle(window)

        #expect(model.cursorPositions.map(\.range) == [match])
    }
}
