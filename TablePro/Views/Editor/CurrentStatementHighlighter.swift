//
//  CurrentStatementHighlighter.swift
//  TablePro
//
//  Highlights the background of the SQL statement under the cursor.
//

import AppKit
import CodeEditSourceEditor
import CodeEditTextView

@MainActor
final class CurrentStatementHighlighter {
    private static let groupId = "tablepro.currentStatement"
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
        // Clear emphasis immediately so stale ranges don't cause drawing crashes.
        // The debounced update will re-apply with the correct range.
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

        let docLength = (textView.string as NSString).length

        // Skip for huge documents
        guard docLength < Self.maxDocumentLength else {
            clearHighlight()
            return
        }

        // Skip for multi-cursor (ambiguous which statement)
        guard controller.cursorPositions.count == 1,
              let cursor = controller.cursorPositions.first else {
            clearHighlight()
            return
        }

        let cursorPos = cursor.range.location

        // Skip if single statement (no semicolons — highlighting everything is meaningless)
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

        // Validate range is within document bounds
        guard stmtRange.length > 0, NSMaxRange(stmtRange) <= docLength else {
            clearHighlight()
            return
        }

        // Skip if same range as last time
        if stmtRange == lastHighlightedRange { return }
        lastHighlightedRange = stmtRange

        let color = ThemeEngine.shared.colors.editor.currentStatementHighlight
        let emphasis = Emphasis(
            range: stmtRange,
            style: .outline(color: color, fill: true)
        )
        textView.emphasisManager?.removeEmphases(for: Self.groupId)
        textView.emphasisManager?.addEmphases([emphasis], for: Self.groupId)
    }

    private func clearHighlight() {
        lastHighlightedRange = nil
        controller?.textView.emphasisManager?.removeEmphases(for: Self.groupId)
    }
}
