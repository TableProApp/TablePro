//
//  CellOverlayViewer.swift
//  TablePro
//

import AppKit

@MainActor
final class CellOverlayViewer: CellOverlayBase, NSTextViewDelegate {
    func show(
        in tableView: NSTableView,
        row: Int,
        column: Int,
        columnIndex: Int,
        value: String
    ) {
        removeOverlay()

        let cellFrame = tableView.frameOfCell(atColumn: column, row: row)
        guard !cellFrame.isEmpty else { return }
        guard let window = tableView.window else { return }

        let frame = Self.overlayFrame(for: cellFrame, value: value)
        let containerView = Self.makeContainer(frame: frame)
        let scrollView = Self.makeScrollView(in: containerView)

        let textView = NSTextView(frame: scrollView.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
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

        install(in: tableView, row: row, column: column, columnIndex: columnIndex, container: containerView)
        window.makeFirstResponder(textView)
    }

    func dismiss() {
        removeOverlay()
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)),
             #selector(NSResponder.cancelOperation(_:)),
             #selector(NSResponder.insertTab(_:)),
             #selector(NSResponder.insertBacktab(_:)):
            removeOverlay()
            return true
        default:
            return false
        }
    }
}
