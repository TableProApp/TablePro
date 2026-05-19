//
//  CellOverlayBase.swift
//  TablePro
//

import AppKit

enum CellOverlayDismissReason {
    case userAction
    case scroll
    case columnResize
    case appResign
    case windowResignKey
    case outsideClick
}

@MainActor
class CellOverlayBase: NSObject {
    private var container: CellOverlayContainerView?
    private weak var hostTableView: NSTableView?
    private var scrollObserver: NSObjectProtocol?
    private var columnResizeObserver: NSObjectProtocol?
    private var appResignObserver: NSObjectProtocol?
    private var windowResignKeyObserver: NSObjectProtocol?
    private var outsideClickMonitor: Any?

    private(set) var row: Int = -1
    private(set) var column: Int = -1
    private(set) var columnIndex: Int = -1

    var isActive: Bool { container != nil }
    var containerView: NSView? { container }
    var tableView: NSTableView? { hostTableView }

    func raiseToFront() {
        guard let container, let hostTableView, container.superview === hostTableView else { return }
        guard hostTableView.subviews.last !== container else { return }
        hostTableView.addSubview(container)
    }

    func install(
        in tableView: NSTableView,
        row: Int,
        column: Int,
        columnIndex: Int,
        container: CellOverlayContainerView
    ) {
        self.hostTableView = tableView
        self.row = row
        self.column = column
        self.columnIndex = columnIndex
        tableView.addSubview(container)
        self.container = container
        installDismissObservers()
    }

    func handleDismiss(reason: CellOverlayDismissReason) {
        removeOverlay()
    }

    func removeOverlay() {
        guard let activeContainer = container else { return }
        removeDismissObservers()
        activeContainer.removeFromSuperview()
        container = nil
        if let hostTableView {
            hostTableView.window?.makeFirstResponder(hostTableView)
        }
    }

    static func overlayFrame(for cellFrame: NSRect, value: String) -> NSRect {
        let lineHeight = ThemeEngine.shared.dataGridFonts.regular.boundingRectForFont.height + 4
        var newlineCount = 0
        for scalar in value.unicodeScalars where scalar == "\n" {
            newlineCount += 1
        }
        let lineCount = CGFloat(newlineCount + 1)
        let contentHeight = max(lineCount * lineHeight + 8, cellFrame.height)
        let height = min(max(contentHeight, cellFrame.height), 120)
        return NSRect(x: cellFrame.origin.x, y: cellFrame.origin.y, width: cellFrame.width, height: height)
    }

    static func makeContainer(frame: NSRect) -> CellOverlayContainerView {
        let container = CellOverlayContainerView(frame: frame)
        container.wantsLayer = true
        container.layer?.borderWidth = 2
        container.layer?.borderColor = NSColor.keyboardFocusIndicatorColor.cgColor
        container.layer?.cornerRadius = 2
        container.layer?.masksToBounds = true
        container.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        return container
    }

    static func makeScrollView(in container: NSView) -> NSScrollView {
        let scrollView = NSScrollView(frame: container.bounds)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        return scrollView
    }

    private func installDismissObservers() {
        guard let hostTableView else { return }

        if let clipView = hostTableView.enclosingScrollView?.contentView {
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: clipView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handleDismiss(reason: .scroll)
                }
            }
        }

        columnResizeObserver = NotificationCenter.default.addObserver(
            forName: NSTableView.columnDidResizeNotification,
            object: hostTableView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleDismiss(reason: .columnResize)
            }
        }

        appResignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleDismiss(reason: .appResign)
            }
        }

        if let overlayWindow = hostTableView.window {
            windowResignKeyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: overlayWindow,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handleDismiss(reason: .windowResignKey)
                }
            }
        }

        outsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
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
            handleDismiss(reason: .outsideClick)
        }
    }
}

final class CellOverlayContainerView: NSView {
    override var isFlipped: Bool { true }
}
