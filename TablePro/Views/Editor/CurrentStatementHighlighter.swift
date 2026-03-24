//
//  CurrentStatementHighlighter.swift
//  TablePro
//
//  Highlights the background of the SQL statement under the cursor.
//  Uses NSTextStorage backgroundColor attribute so syntax colors are preserved.
//

import AppKit
import CodeEditSourceEditor
import CodeEditTextView

@MainActor
final class CurrentStatementHighlighter {
    private static let debounceInterval: TimeInterval = 0.15
    private static let maxDocumentLength = 5_000_000

    private weak var controller: TextViewController?
    private var debounceWorkItem: DispatchWorkItem?
    private var lastHighlightedRange: NSRange?
    private var generation: UInt64 = 0

    func install(controller: TextViewController) {
        self.controller = controller
    }

    func uninstall() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        clearHighlight()
        controller = nil
    }

    func handleCursorChange() {
        scheduleUpdate()
    }

    func handleTextChange() {
        clearHighlight()
        scheduleUpdate()
    }

    private func scheduleUpdate() {
        debounceWorkItem?.cancel()
        generation &+= 1
        let currentGeneration = generation

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.generation == currentGeneration else { return }
            self.updateHighlight()
        }
        debounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounceInterval, execute: workItem)
    }

    private func updateHighlight() {
        guard let controller, let textView = controller.textView else {
            clearHighlight()
            return
        }

        guard let storage = textView.textStorage else {
            clearHighlight()
            return
        }
        let docLength = (textView.string as NSString).length

        guard docLength > 0, docLength < Self.maxDocumentLength else {
            clearHighlight()
            return
        }

        guard controller.cursorPositions.count == 1,
              let cursor = controller.cursorPositions.first else {
            clearHighlight()
            return
        }

        let cursorPos = cursor.range.location

        // Skip if single statement (no semicolons)
        let nsString = textView.string as NSString
        guard nsString.range(of: ";").location != NSNotFound else {
            clearHighlight()
            return
        }

        let located = SQLStatementScanner.locatedStatementAtCursor(
            in: textView.string,
            cursorPosition: cursorPos
        )

        let stmtNS = located.sql as NSString
        let stmtRange = NSRange(location: located.offset, length: stmtNS.length)

        guard stmtRange.length > 0, NSMaxRange(stmtRange) <= docLength else {
            clearHighlight()
            return
        }

        if stmtRange == lastHighlightedRange { return }

        // Remove old highlight, apply new one
        if let old = lastHighlightedRange, NSMaxRange(old) <= storage.length {
            storage.removeAttribute(.backgroundColor, range: old)
        }
        lastHighlightedRange = stmtRange

        let color = ThemeEngine.shared.colors.editor.currentStatementHighlight
        storage.addAttribute(.backgroundColor, value: color, range: stmtRange)
    }

    private func clearHighlight() {
        if let storage = controller?.textView.textStorage,
           let old = lastHighlightedRange,
           NSMaxRange(old) <= storage.length {
            storage.removeAttribute(.backgroundColor, range: old)
        }
        lastHighlightedRange = nil
    }
}
