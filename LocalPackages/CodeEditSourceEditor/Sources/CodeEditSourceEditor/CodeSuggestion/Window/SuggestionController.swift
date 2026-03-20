//
//  SuggestionController.swift
//  CodeEditTextView
//
//  Created by Abe Malla on 6/18/24.
//

import AppKit
import CodeEditTextView
import Combine
import SwiftUI

public final class SuggestionController: NSWindowController {
    static var shared: SuggestionController = SuggestionController()

    // MARK: - Properties

    /// Whether the suggestion window is visible
    var isVisible: Bool {
        window?.isVisible ?? false || popover?.isShown ?? false
    }

    var model: SuggestionViewModel = SuggestionViewModel()

    // MARK: - Private Properties

    /// Maximum number of visible rows (8.5)
    static let MAX_VISIBLE_ROWS: CGFloat = 8.5
    /// Padding at top and bottom of the window
    static let WINDOW_PADDING: CGFloat = 5

    /// Tracks when the window is placed above the cursor
    var isWindowAboveCursor = false

    var popover: NSPopover?

    /// Holds the observer for the window resign notifications
    private var windowResignObserver: NSObjectProtocol?
    /// Closes autocomplete when first responder changes away from the active text view
    private var firstResponderObserver: NSObjectProtocol?
    private var localEventMonitor: Any?
    private var sizeObservers: Set<AnyCancellable> = []

    // MARK: - Initialization

    public init() {
        let window = Self.makeWindow()
        super.init(window: window)

        let contentView = SuggestionContentView(model: model)
        let hostingView = NSHostingView(rootView: contentView)
        window.contentView = hostingView

        // Resize window when items change
        model.$items
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateWindowSizeFromContent()
            }
            .store(in: &sizeObservers)

        // Resize window only when preview visibility changes (not every arrow key)
        model.$selectedIndex
            .receive(on: DispatchQueue.main)
            .map { [weak self] index -> Bool in
                guard let self, index >= 0, index < self.model.items.count else { return false }
                let item = self.model.items[index]
                return item.documentation != nil || item.sourcePreview != nil
                    || !(item.pathComponents?.isEmpty ?? true)
            }
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.updateWindowSizeFromContent()
            }
            .store(in: &sizeObservers)

        if window.isVisible {
            window.close()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Show Completions

    func showCompletions(
        textView: TextViewController,
        delegate: CodeSuggestionDelegate,
        cursorPosition: CursorPosition,
        isManualTrigger: Bool = false,
        asPopover: Bool = false
    ) {
        model.showCompletions(
            textView: textView,
            delegate: delegate,
            cursorPosition: cursorPosition,
            isManualTrigger: isManualTrigger
        ) { parentWindow, cursorRect in
            self.model.updateTheme(from: textView)

            if asPopover {
                self.popover?.close()
                self.popover = nil

                let windowPosition = parentWindow.convertFromScreen(cursorRect)
                let textViewPosition = textView.textView.convert(windowPosition, from: nil)
                let popover = NSPopover()
                popover.behavior = .transient

                let controller = NSHostingController(rootView: SuggestionContentView(model: self.model))
                popover.contentViewController = controller
                popover.show(relativeTo: textViewPosition, of: textView.textView, preferredEdge: .maxY)
                self.popover = popover
            } else {
                self.showWindow(attachedTo: parentWindow)
                self.constrainWindowToScreenEdges(cursorRect: cursorRect, font: textView.font)
            }
        }
    }

    /// Opens the window as a child of another window.
    public func showWindow(attachedTo parentWindow: NSWindow) {
        guard let window = window else { return }
        parentWindow.addChildWindow(window, ordered: .above)

        if let existingObserver = windowResignObserver {
            NotificationCenter.default.removeObserver(existingObserver)
        }
        windowResignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: parentWindow,
            queue: .main
        ) { [weak self] _ in
            self?.close()
        }

        // Close when the active text view is removed (e.g., tab closed/switched)
        if let existingObserver = firstResponderObserver {
            NotificationCenter.default.removeObserver(existingObserver)
        }
        firstResponderObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification,
            object: parentWindow,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            guard let textView = self.model.activeTextView else {
                self.close()
                return
            }
            // Close if text view removed from window or lost first responder
            if textView.view.window == nil {
                self.close()
            } else if let firstResponder = textView.view.window?.firstResponder as? NSView,
                      !firstResponder.isDescendant(of: textView.view) {
                self.close()
            }
        }

        setupEventMonitors()
        super.showWindow(nil)
        window.orderFront(nil)
    }

    /// Close the window
    public override func close() {
        model.willClose()
        removeEventMonitors()

        if let observer = windowResignObserver {
            NotificationCenter.default.removeObserver(observer)
            windowResignObserver = nil
        }

        if let observer = firstResponderObserver {
            NotificationCenter.default.removeObserver(observer)
            firstResponderObserver = nil
        }

        if popover != nil {
            popover?.close()
            popover = nil
        }

        super.close()
    }

    // MARK: - Cursors Updated

    func cursorsUpdated(
        textView: TextViewController,
        delegate: CodeSuggestionDelegate,
        position: CursorPosition,
        presentIfNot: Bool = false,
        asPopover: Bool = false
    ) {
        if !asPopover && popover != nil {
            close()
        }

        model.cursorsUpdated(textView: textView, delegate: delegate, position: position) {
            close()

            if presentIfNot {
                self.showCompletions(
                    textView: textView,
                    delegate: delegate,
                    cursorPosition: position,
                    asPopover: asPopover
                )
            }
        }
    }

    // MARK: - Keyboard Event Monitoring

    private func setupEventMonitors() {
        removeEventMonitors()
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }

            // Close if the active text view was removed from its window (e.g., tab closed)
            if self.model.activeTextView == nil || self.model.activeTextView?.view.window == nil {
                self.close()
                return event
            }

            switch event.keyCode {
            case 53: // Escape
                self.close()
                return nil
            case 125: // Down Arrow
                self.model.moveDown()
                return nil
            case 126: // Up Arrow
                self.model.moveUp()
                return nil
            case 36, 48: // Return, Tab
                if let item = self.model.selectedItem {
                    self.model.applySelectedItem(item: item, window: self.window)
                }
                return nil
            default:
                return event
            }
        }
    }

    private func removeEventMonitors() {
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }
    }
}
