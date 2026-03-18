//
//  CellOverlayEditor.swift
//  TablePro
//
//  Overlay editor for multiline cell values.
//  Uses NSScrollView + NSTextView positioned on top of the cell,
//  bypassing NSTextFieldCell's field editor which cannot scroll vertically.
//

import AppKit

/// Overlay editor that displays a scrollable NSTextView on top of a data grid cell
/// for editing multiline content. Commits on Enter, cancels on Escape, and
/// navigates cells with Tab/Shift+Tab.
@MainActor
final class CellOverlayEditor: NSObject, NSTextViewDelegate {
    private var scrollView: NSScrollView?
    private weak var tableView: NSTableView?
    private var clickMonitor: Any?
    private var scrollObserver: NSObjectProtocol?
    private var columnResizeObserver: NSObjectProtocol?

    private(set) var row: Int = -1
    private(set) var column: Int = -1
    private(set) var columnIndex: Int = -1

    /// Called with the new string value when the edit is committed
    var onCommit: ((_ row: Int, _ columnIndex: Int, _ newValue: String) -> Void)?

    /// Called when the user presses Tab or Shift+Tab to navigate
    var onTabNavigation: ((_ row: Int, _ column: Int, _ forward: Bool) -> Void)?

    /// Whether the overlay is currently active
    var isActive: Bool { scrollView != nil }

    // MARK: - Show / Dismiss

    /// Show the overlay editor on top of the specified cell
    func show(
        in tableView: NSTableView,
        row: Int,
        column: Int,
        columnIndex: Int,
        value: String
    ) {
        dismiss(commit: false)

        self.tableView = tableView
        self.row = row
        self.column = column
        self.columnIndex = columnIndex

        guard let cellView = tableView.view(atColumn: column, row: row, makeIfNecessary: false) else { return }

        // Convert cell frame to table view coordinates
        let cellRect = cellView.convert(cellView.bounds, to: tableView)

        // Determine overlay height — at least the cell height, up to 120pt
        let lineHeight: CGFloat = ThemeEngine.shared.dataGridFonts.regular.boundingRectForFont.height + 4
        let lineCount = CGFloat(value.components(separatedBy: .newlines).count)
        let contentHeight = max(lineCount * lineHeight + 8, cellRect.height)
        let overlayHeight = min(contentHeight, 120)

        let overlayRect = NSRect(
            x: cellRect.origin.x,
            y: cellRect.origin.y,
            width: cellRect.width,
            height: overlayHeight
        )

        // Build text view
        let textView = OverlayTextView(frame: NSRect(origin: .zero, size: overlayRect.size))
        textView.overlayEditor = self
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = ThemeEngine.shared.dataGridFonts.regular
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: overlayRect.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.delegate = self
        textView.string = value
        textView.selectAll(nil)

        // Build scroll view
        let sv = NSScrollView(frame: overlayRect)
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = false
        sv.autohidesScrollers = true
        sv.borderType = .noBorder
        sv.documentView = textView
        sv.drawsBackground = true
        sv.backgroundColor = .textBackgroundColor

        // Visual border to indicate editing state
        sv.wantsLayer = true
        sv.layer?.borderWidth = 2
        sv.layer?.borderColor = NSColor.selectedControlColor.cgColor
        sv.layer?.cornerRadius = 2

        tableView.addSubview(sv)
        scrollView = sv

        // Make text view first responder
        tableView.window?.makeFirstResponder(textView)

        // Install click-outside monitor
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let sv = self.scrollView, sv.window != nil else { return event }
            let locationInSV = sv.convert(event.locationInWindow, from: nil)
            if !sv.bounds.contains(locationInSV) {
                self.dismiss(commit: true)
            }
            return event
        }

        // Observe table scroll → commit and dismiss
        if let clipView = tableView.enclosingScrollView?.contentView {
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: clipView,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.dismiss(commit: true)
                }
            }
        }

        // Observe column resize → commit and dismiss
        columnResizeObserver = NotificationCenter.default.addObserver(
            forName: NSTableView.columnDidResizeNotification,
            object: tableView,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.dismiss(commit: true)
            }
        }
    }

    /// Dismiss the overlay, optionally committing the current text
    func dismiss(commit: Bool) {
        guard let sv = scrollView, let textView = sv.documentView as? NSTextView else { return }

        let newValue = textView.string

        // Remove observers before tearing down
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
        if let observer = scrollObserver {
            NotificationCenter.default.removeObserver(observer)
            scrollObserver = nil
        }
        if let observer = columnResizeObserver {
            NotificationCenter.default.removeObserver(observer)
            columnResizeObserver = nil
        }

        // Restore first responder to table view before removing overlay
        if let tableView {
            tableView.window?.makeFirstResponder(tableView)
        }

        sv.removeFromSuperview()
        scrollView = nil

        if commit {
            onCommit?(row, columnIndex, newValue)
        }
    }

    // MARK: - NSTextViewDelegate

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        // Enter → commit
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            // Option+Enter → insert actual newline
            if NSApp.currentEvent?.modifierFlags.contains(.option) == true {
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            }
            dismiss(commit: true)
            return true
        }

        // Escape → cancel
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            dismiss(commit: false)
            return true
        }

        // Tab → commit and navigate forward
        if commandSelector == #selector(NSResponder.insertTab(_:)) {
            let r = row, c = column
            dismiss(commit: true)
            onTabNavigation?(r, c, true)
            return true
        }

        // Shift+Tab → commit and navigate backward
        if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
            let r = row, c = column
            dismiss(commit: true)
            onTabNavigation?(r, c, false)
            return true
        }

        // Up/Down arrows — let NSTextView handle natively for line navigation
        return false
    }
}

// MARK: - Overlay Text View

/// NSTextView subclass that commits and dismisses the overlay editor when
/// the user presses a menu key equivalent (e.g. Cmd+S) so the shortcut
/// propagates to the SwiftUI menu system instead of being swallowed.
private final class OverlayTextView: NSTextView {
    weak var overlayEditor: CellOverlayEditor?

    /// Key equivalents that should commit the edit and bubble up to the menu bar.
    private static let menuKeyEquivalents: Set<String> = ["s"]

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
