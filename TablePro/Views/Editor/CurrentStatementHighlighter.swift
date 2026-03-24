//
//  CurrentStatementHighlighter.swift
//  TablePro
//
//  Highlights the background of the SQL statement under the cursor.
//  Uses a CALayer behind text so syntax colors and cursor are preserved.
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
    private let backgroundLayer = CALayer()
    /// Saved current-line highlight color to restore when statement highlight is inactive.
    private var savedLineHighlightColor: NSColor?
    private var isLineHighlightSuppressed = false

    func install(controller: TextViewController) {
        self.controller = controller
        backgroundLayer.zPosition = -1
        controller.textView.layer?.addSublayer(backgroundLayer)
    }

    func uninstall() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        restoreLineHighlight()
        backgroundLayer.removeFromSuperlayer()
        lastHighlightedRange = nil
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
        lastHighlightedRange = stmtRange

        // Get bounding rect from layout manager via the rounded path
        guard let path = textView.layoutManager?.roundedPathForRange(stmtRange, cornerRadius: 0) else {
            clearHighlight()
            return
        }
        let rect = path.bounds

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let color = ThemeEngine.shared.colors.editor.currentStatementHighlight
        backgroundLayer.backgroundColor = color.cgColor
        backgroundLayer.cornerRadius = 3
        // Extend to full width of the text view
        backgroundLayer.frame = CGRect(
            x: 0,
            y: rect.origin.y,
            width: textView.frame.width,
            height: rect.height
        )
        backgroundLayer.isHidden = false
        CATransaction.commit()

        suppressLineHighlight()
    }

    private func clearHighlight() {
        lastHighlightedRange = nil
        backgroundLayer.isHidden = true
        restoreLineHighlight()
    }

    /// Hide the editor's built-in current-line highlight to avoid double-highlight.
    private func suppressLineHighlight() {
        guard !isLineHighlightSuppressed else { return }
        let selMgr = controller?.textView.selectionManager
        savedLineHighlightColor = selMgr?.selectedLineBackgroundColor
        selMgr?.selectedLineBackgroundColor = .clear
        isLineHighlightSuppressed = true
    }

    /// Restore the editor's built-in current-line highlight.
    private func restoreLineHighlight() {
        guard isLineHighlightSuppressed else { return }
        controller?.textView.selectionManager?.selectedLineBackgroundColor = savedLineHighlightColor ?? .clear
        isLineHighlightSuppressed = false
    }
}
