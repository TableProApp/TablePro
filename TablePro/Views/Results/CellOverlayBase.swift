//
//  CellOverlayBase.swift
//  TablePro
//

import AppKit

enum CellOverlayDismissReason {
    case userAction
    case scroll
    case columnGeometry
    case appResign
    case windowResignKey
    case outsideClick
}

@MainActor
class CellOverlayBase: NSObject {
    private var container: CellOverlayContainerView?
    private weak var hostTableView: NSTableView?
    private var scrollObserver: NSObjectProtocol?
    private var columnGeometryObservers: [any NSObjectProtocol] = []
    private var appResignObserver: NSObjectProtocol?
    private var windowResignKeyObserver: NSObjectProtocol?
    private var outsideClickMonitor: Any?
    var onRemove: (() -> Void)?

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
        setOverlayCell(CellPosition(row: row, column: columnIndex), in: tableView)
        selectionOverlay(in: tableView)?.needsDisplay = true
        installDismissObservers()
    }

    /// The cell under the overlay draws no text of its own behind it. A drawn cell has no view to
    /// carry that, so the coordinator holds it and repaints the cell either side of the change.
    private func setOverlayCell(_ position: CellPosition?, in tableView: NSTableView) {
        (tableView as? KeyHandlingTableView)?.coordinator?.overlayCell = position
    }

    private func selectionOverlay(in tableView: NSTableView) -> GridSelectionOverlay? {
        (tableView as? KeyHandlingTableView)?.selectionOverlay
    }

    func handleDismiss(reason: CellOverlayDismissReason) {
        removeOverlay()
    }

    func removeOverlay() {
        guard let activeContainer = container else { return }
        removeDismissObservers()
        if let hostTableView {
            setOverlayCell(nil, in: hostTableView)
            selectionOverlay(in: hostTableView)?.needsDisplay = true
        }
        activeContainer.removeFromSuperview()
        container = nil
        if let hostTableView {
            hostTableView.window?.makeFirstResponder(hostTableView)
        }
        onRemove?()
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
        container.layer?.cornerRadius = 2
        container.layer?.masksToBounds = true
        container.applyLayerColors()
        return container
    }

    /// Lays a text view out the way an inline cell overlay needs.
    ///
    /// A cell holds one value, so the overlay behaves like a field editor and scrolls a long line
    /// rather than wrapping it. Wrapping made TextKit 2 lay the whole value out before the overlay
    /// could appear: measured at 206ms for a 256KB value and 816ms for 1MB, against 7ms unwrapped,
    /// and the wrapped result was thousands of visual lines in a box 120pt tall (#2381).
    ///
    /// `maxSize` is raised with the container because a text view grows only as far as `maxSize`,
    /// which `init(frame:)` leaves at the frame: without it the long line is clipped at the cell's
    /// width instead of scrolled, measured as a 140pt document against 344,166pt with it raised.
    static func applyCellTextLayout(to textView: NSTextView) {
        let unbounded = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.maxSize = unbounded
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = unbounded
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

        columnGeometryObservers = [
            NSTableView.columnDidResizeNotification,
            NSTableView.columnDidMoveNotification,
        ].map { name in
            NotificationCenter.default.addObserver(forName: name, object: hostTableView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handleDismiss(reason: .columnGeometry)
                }
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
        columnGeometryObservers.forEach(NotificationCenter.default.removeObserver)
        columnGeometryObservers = []
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

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyLayerColors()
    }

    /// A `CGColor` is a resolved colour and a layer never resolves it again, so the two layer
    /// colours are reapplied whenever the appearance changes under an open overlay.
    func applyLayerColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = NSColor.keyboardFocusIndicatorColor.cgColor
            layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        }
    }
}
