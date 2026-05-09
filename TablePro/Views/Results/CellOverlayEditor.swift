//
//  CellOverlayEditor.swift
//  TablePro
//

import AppKit

@MainActor
final class CellOverlayEditor: NSObject, NSTextViewDelegate {
    private var container: OverlayContainerView?
    private var textView: OverlayTextView?
    private weak var tableView: NSTableView?
    private var scrollObserver: NSObjectProtocol?
    private var columnResizeObserver: NSObjectProtocol?
    private var appResignObserver: NSObjectProtocol?
    private var windowResignKeyObserver: NSObjectProtocol?
    private var outsideClickMonitor: Any?

    private(set) var row: Int = -1
    private(set) var column: Int = -1
    private(set) var columnIndex: Int = -1

    var onCommit: ((_ row: Int, _ columnIndex: Int, _ newValue: String) -> Void)?
    var onTabNavigation: ((_ row: Int, _ column: Int, _ forward: Bool) -> Void)?

    var isActive: Bool { container != nil }

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

        let cellFrame = tableView.frameOfCell(atColumn: column, row: row)
        guard !cellFrame.isEmpty else { return }
        guard let window = tableView.window else { return }

        let lineHeight = ThemeEngine.shared.dataGridFonts.regular.boundingRectForFont.height + 4
        var newlineCount = 0
        for scalar in value.unicodeScalars where scalar == "\n" {
            newlineCount += 1
        }
        let lineCount = CGFloat(newlineCount + 1)
        let contentHeight = max(lineCount * lineHeight + 8, cellFrame.height)
        let overlayHeight = min(max(contentHeight, cellFrame.height), 120)

        let editorFrame = NSRect(
            x: cellFrame.origin.x,
            y: cellFrame.origin.y,
            width: cellFrame.width,
            height: overlayHeight
        )

        let containerView = OverlayContainerView(frame: editorFrame)
        containerView.wantsLayer = true
        containerView.layer?.borderWidth = 2
        containerView.layer?.borderColor = NSColor.keyboardFocusIndicatorColor.cgColor
        containerView.layer?.cornerRadius = 2
        containerView.layer?.masksToBounds = true
        containerView.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor

        let scrollView = NSScrollView(frame: containerView.bounds)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        let editorTextView = OverlayTextView(frame: scrollView.bounds)
        editorTextView.overlayEditor = self
        editorTextView.isRichText = false
        editorTextView.allowsUndo = true
        editorTextView.font = ThemeEngine.shared.dataGridFonts.regular
        editorTextView.textColor = .labelColor
        editorTextView.backgroundColor = .textBackgroundColor
        editorTextView.isVerticallyResizable = true
        editorTextView.isHorizontallyResizable = false
        editorTextView.textContainer?.widthTracksTextView = true
        editorTextView.textContainer?.containerSize = NSSize(
            width: scrollView.bounds.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        editorTextView.delegate = self
        editorTextView.string = value
        editorTextView.selectAll(nil)

        scrollView.documentView = editorTextView
        containerView.addSubview(scrollView)

        tableView.addSubview(containerView)
        container = containerView
        textView = editorTextView

        window.makeFirstResponder(editorTextView)

        installDismissObservers()
    }

    func dismiss(commit: Bool) {
        guard let activeContainer = container, let activeTextView = textView else { return }

        let newValue = activeTextView.string

        removeDismissObservers()

        activeContainer.removeFromSuperview()
        container = nil
        textView = nil

        if let tableView {
            tableView.window?.makeFirstResponder(tableView)
        }

        if commit {
            onCommit?(row, columnIndex, newValue)
        }
    }

    // MARK: - Observers

    private func installDismissObservers() {
        guard let tableView else { return }

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

        appResignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.dismiss(commit: true)
            }
        }

        if let editorWindow = tableView.window {
            windowResignKeyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: editorWindow,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.dismiss(commit: true)
                }
            }
        }

        outsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            Task { @MainActor [weak self] in
                self?.handleOutsideClick(event: event)
            }
            return event
        }
    }

    private func removeDismissObservers() {
        if let observer = scrollObserver {
            NotificationCenter.default.removeObserver(observer)
            scrollObserver = nil
        }
        if let observer = columnResizeObserver {
            NotificationCenter.default.removeObserver(observer)
            columnResizeObserver = nil
        }
        if let observer = appResignObserver {
            NotificationCenter.default.removeObserver(observer)
            appResignObserver = nil
        }
        if let observer = windowResignKeyObserver {
            NotificationCenter.default.removeObserver(observer)
            windowResignKeyObserver = nil
        }
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }

    private func handleOutsideClick(event: NSEvent) {
        guard let containerView = container,
              let containerWindow = containerView.window,
              event.window === containerWindow else { return }
        let frameInWindow = containerView.convert(containerView.bounds, to: nil)
        if !frameInWindow.contains(event.locationInWindow) {
            dismiss(commit: true)
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

// MARK: - Container View

private final class OverlayContainerView: NSView {
    override var isFlipped: Bool { true }
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
