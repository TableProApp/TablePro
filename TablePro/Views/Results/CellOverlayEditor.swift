//
//  CellOverlayEditor.swift
//  TablePro
//

import AppKit

@MainActor
final class CellOverlayEditor: CellOverlayBase, NSTextViewDelegate {
    private var editorTextView: OverlayTextView?
    private var editorScrollView: NSScrollView?
    private var editedCellFrame: NSRect = .zero
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
        let font = ThemeEngine.shared.valueFont
        let containerView = Self.makeContainer(frame: frame)
        let scrollView = Self.makeScrollView(
            in: containerView, scrollsVertically: frame.height > cellFrame.height
        )

        let textView = OverlayTextView(frame: scrollView.bounds)
        textView.overlayEditor = self
        textView.isEditable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = font
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.focusRingType = .none
        Self.applyCellTextLayout(to: textView)
        Self.configureCellTextGeometry(of: textView, rowHeight: cellFrame.height, font: font)
        textView.delegate = self
        textView.string = value
        textView.selectAll(nil)

        scrollView.documentView = textView
        containerView.addSubview(scrollView)

        initialValue = value
        editorTextView = textView
        editorScrollView = scrollView
        editedCellFrame = cellFrame

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
        editorScrollView = nil
        editedCellFrame = .zero
        initialValue = ""
        removeOverlay()

        if commit, newValue != originalValue {
            onCommit?(dismissRow, dismissColumnIndex, newValue)
        }
    }

    /// Option+Return and pasted text can turn a single-line edit into a multiline one after
    /// the overlay opened, and the row-height overlay would clip the new lines with no
    /// affordance that they exist. The frame follows the text, exactly as it would have been
    /// framed had the value arrived that way.
    func textDidChange(_ notification: Notification) {
        guard let textView = editorTextView, let container = containerView else { return }
        let frame = Self.overlayFrame(for: editedCellFrame, value: textView.string)
        guard frame != container.frame else { return }
        container.frame = frame
        let grew = frame.height > editedCellFrame.height
        editorScrollView?.hasVerticalScroller = grew
        editorScrollView?.verticalScrollElasticity = grew ? .automatic : .none
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
