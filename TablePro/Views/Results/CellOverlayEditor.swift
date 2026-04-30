//
//  CellOverlayEditor.swift
//  TablePro
//
//  Overlay editor for multiline cell values.
//  Uses a borderless NSPanel containing an NSScrollView + NSTextView,
//  bypassing NSTextFieldCell's field editor which cannot scroll vertically.
//

import AppKit

@MainActor
final class CellOverlayEditor: NSObject, NSTextViewDelegate {
    private var panel: CellOverlayPanel?
    private weak var tableView: NSTableView?
    private var scrollObserver: NSObjectProtocol?
    private var columnResizeObserver: NSObjectProtocol?

    private(set) var row: Int = -1
    private(set) var column: Int = -1
    private(set) var columnIndex: Int = -1

    var onCommit: ((_ row: Int, _ columnIndex: Int, _ newValue: String) -> Void)?

    var onTabNavigation: ((_ row: Int, _ column: Int, _ forward: Bool) -> Void)?

    var isActive: Bool { panel != nil }

    // MARK: - Show / Dismiss

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
        guard let window = tableView.window else { return }

        let cellRectInWindow = cellView.convert(cellView.bounds, to: nil)
        let cellRectOnScreen = window.convertToScreen(cellRectInWindow)

        let lineHeight: CGFloat = ThemeEngine.shared.dataGridFonts.regular.boundingRectForFont.height + 4
        var newlineCount = 0
        for scalar in value.unicodeScalars where scalar == "\n" {
            newlineCount += 1
        }
        let lineCount = CGFloat(newlineCount + 1)
        let contentHeight = max(lineCount * lineHeight + 8, cellRectOnScreen.height)
        let overlayHeight = min(contentHeight, 120)

        let panelRect = NSRect(
            x: cellRectOnScreen.origin.x,
            y: cellRectOnScreen.origin.y - (overlayHeight - cellRectOnScreen.height),
            width: cellRectOnScreen.width,
            height: overlayHeight
        )

        let contentSize = NSSize(width: panelRect.width, height: panelRect.height)

        let textView = OverlayTextView(frame: NSRect(origin: .zero, size: contentSize))
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
            width: contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.delegate = self
        textView.string = value
        textView.selectAll(nil)

        let scrollView = NSScrollView(frame: NSRect(origin: .zero, size: contentSize))
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.autoresizingMask = [.width, .height]

        let newPanel = CellOverlayPanel(
            contentRect: panelRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        newPanel.level = .floating
        newPanel.hidesOnDeactivate = false
        newPanel.isReleasedWhenClosed = false
        newPanel.hasShadow = true
        newPanel.backgroundColor = .textBackgroundColor
        newPanel.isOpaque = false
        newPanel.contentView = scrollView
        newPanel.contentView?.wantsLayer = true
        newPanel.contentView?.layer?.borderWidth = 2
        newPanel.contentView?.layer?.borderColor = NSColor.keyboardFocusIndicatorColor.safeCGColor
        newPanel.contentView?.layer?.cornerRadius = 2
        newPanel.contentView?.layer?.masksToBounds = true

        newPanel.onResignKey = { [weak self] in
            self?.dismiss(commit: true)
        }

        panel = newPanel

        newPanel.makeKeyAndOrderFront(nil)
        newPanel.makeFirstResponder(textView)

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

        columnResizeObserver = NotificationCenter.default.addObserver(
            forName: NSTableView.columnDidResizeNotification,
            object: tableView,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.dismiss(commit: false)
            }
        }
    }

    func dismiss(commit: Bool) {
        guard let activePanel = panel,
              let scrollView = activePanel.contentView as? NSScrollView,
              let textView = scrollView.documentView as? NSTextView else { return }

        let newValue = textView.string

        activePanel.onResignKey = nil

        if let observer = scrollObserver {
            NotificationCenter.default.removeObserver(observer)
            scrollObserver = nil
        }
        if let observer = columnResizeObserver {
            NotificationCenter.default.removeObserver(observer)
            columnResizeObserver = nil
        }

        activePanel.orderOut(nil)
        panel = nil

        if let tableView {
            tableView.window?.makeFirstResponder(tableView)
        }

        if commit {
            onCommit?(row, columnIndex, newValue)
        }
    }

    // MARK: - NSTextViewDelegate

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
            let r = row, c = column
            dismiss(commit: true)
            onTabNavigation?(r, c, true)
            return true
        }

        if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
            let r = row, c = column
            dismiss(commit: true)
            onTabNavigation?(r, c, false)
            return true
        }

        return false
    }
}

// MARK: - Overlay Panel

private final class CellOverlayPanel: NSPanel {
    var onResignKey: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}

// MARK: - Overlay Text View

private final class OverlayTextView: NSTextView {
    weak var overlayEditor: CellOverlayEditor?

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
