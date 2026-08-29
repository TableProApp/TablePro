//
//  CellOverlayEditor.swift
//  TablePro
//

import AppKit

@MainActor
final class CellOverlayEditor: CellOverlayBase, NSTextViewDelegate {
    private var editorTextView: OverlayTextView?
    private var initialValue: String = ""

    var onCommit: ((_ row: Int, _ columnIndex: Int, _ newValue: String) -> Void)?
    var onMovement: ((_ row: Int, _ column: Int, _ movement: CellEditorMovement) -> Void)?

    func show(
        in tableView: NSTableView,
        row: Int,
        column: Int,
        columnIndex: Int,
        value: String
    ) {
        dismiss(commit: true)

        let cellFrame = tableView.frameOfCell(atColumn: column, row: row)
        guard !cellFrame.isEmpty else { return }
        guard let window = tableView.window else { return }

        let frame = Self.overlayFrame(for: cellFrame, value: value)
        let containerView = Self.makeContainer(frame: frame)
        let scrollView = Self.makeScrollView(in: containerView)

        let textView = OverlayTextView(frame: scrollView.bounds)
        textView.overlayEditor = self
        textView.isEditable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = ThemeEngine.shared.valueFont
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.focusRingType = .none
        Self.applyCellTextLayout(to: textView)
        textView.delegate = self
        textView.string = value
        textView.selectAll(nil)

        scrollView.documentView = textView
        containerView.addSubview(scrollView)

        initialValue = value
        editorTextView = textView

        install(in: tableView, row: row, column: column, columnIndex: columnIndex, container: containerView)
        window.makeFirstResponder(textView)
    }

    override func handleDismiss(reason: CellOverlayDismissReason) {
        dismiss(commit: reason != .columnGeometry)
    }

    func dismiss(commit: Bool) {
        guard let activeTextView = editorTextView else { return }
        let newValue = activeTextView.string
        let originalValue = initialValue
        let dismissRow = row
        let dismissColumnIndex = columnIndex

        editorTextView = nil
        initialValue = ""
        removeOverlay()

        if commit, newValue != originalValue {
            onCommit?(dismissRow, dismissColumnIndex, newValue)
        }
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if NSApp.currentEvent?.modifierFlags.contains(.option) == true {
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            }
            dismiss(commit: true)
            return true
        }

        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            dismiss(commit: false)
            return true
        }

        if commandSelector == #selector(NSResponder.insertTab(_:)) {
            return leave(with: .tab, from: textView)
        }

        if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
            return leave(with: .backtab, from: textView)
        }

        if commandSelector == #selector(NSResponder.moveUp(_:)) {
            return leaveVertically(.up, from: textView)
        }

        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            return leaveVertically(.down, from: textView)
        }

        return false
    }

    /// Only the plain arrows are read. Shift, Option and Command each map to a selector of their
    /// own, so extending a selection or jumping to the end of the value keeps its native meaning.
    ///
    /// An unhandled arrow moves the caret inside marked text, which is what it is for, so a
    /// composition takes it back rather than having it swallowed.
    private func leaveVertically(_ movement: CellEditorMovement, from textView: NSTextView) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        let exit = CellEditorArrowExit(
            text: textView.string as NSString,
            selection: textView.selectedRange()
        )
        let leaves = movement == .up ? exit.canExitUp : exit.canExitDown
        guard leaves else { return false }
        return leave(with: movement, from: textView)
    }

    /// A composition in progress owns the keystroke. Until the input method commits it the text
    /// view holds provisional text, and leaving the cell would save that half-composed value and
    /// carry the editor off it. The key is swallowed rather than passed back, because a literal
    /// tab in a cell is not what Tab was pressed for.
    private func leave(with movement: CellEditorMovement, from textView: NSTextView) -> Bool {
        guard !textView.hasMarkedText() else { return true }
        let dismissRow = row, dismissColumn = column
        dismiss(commit: true)
        onMovement?(dismissRow, dismissColumn, movement)
        return true
    }
}

private final class OverlayTextView: NSTextView {
    private let storedUndoManager = UndoManager()

    weak var overlayEditor: CellOverlayEditor?

    private static let menuKeyEquivalents: Set<String> = ["s"]

    override var undoManager: UndoManager? { storedUndoManager }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command),
           let chars = event.charactersIgnoringModifiers,
           Self.menuKeyEquivalents.contains(chars) {
            overlayEditor?.dismiss(commit: true)
            return false
        }
        return super.performKeyEquivalent(with: event)
    }
}
