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
    var onTabNavigation: ((_ row: Int, _ column: Int, _ forward: Bool) -> Void)?

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
        textView.font = ThemeEngine.shared.dataGridFonts.regular
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.bounds.width,
            height: CGFloat.greatestFiniteMagnitude
        )
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
        dismiss(commit: reason != .columnResize)
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
            let dismissRow = row, dismissColumn = column
            dismiss(commit: true)
            onTabNavigation?(dismissRow, dismissColumn, true)
            return true
        }

        if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
            let dismissRow = row, dismissColumn = column
            dismiss(commit: true)
            onTabNavigation?(dismissRow, dismissColumn, false)
            return true
        }

        return false
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
