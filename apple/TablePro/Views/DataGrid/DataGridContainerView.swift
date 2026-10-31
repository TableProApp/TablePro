//
//  DataGridContainerView.swift
//  TablePro
//

import AppKit

// Two tables scrolled in step, per Apple's "Synchronizing Scroll Views": NSTableView has no per-column freeze.
@MainActor
final class DataGridContainerView: NSView {
    let main = DataGridPane(kind: .main)
    let frozen = DataGridPane(kind: .frozen)
    weak var controller: DataGridViewController?

    private(set) var gridHasFocus = false
    private var isSyncingScroll = false
    private var firstResponderObservation: NSKeyValueObservation?
    private var windowObservers: [NSObjectProtocol] = []
    private var scrollObservers: [NSObjectProtocol] = []
    private var pageScrollObserver: NSObjectProtocol?

    // A grid sized to its rows moves only with its page, so the page's scroll stands in for its own.
    var followsPageScroll = false {
        didSet {
            guard followsPageScroll != oldValue else { return }
            observePageScroll()
        }
    }

    var frozenPaneWidth: CGFloat = 0 {
        didSet {
            guard frozenPaneWidth != oldValue else { return }
            layoutFrozenPane()
        }
    }

    var panes: [DataGridPane] { [main, frozen] }

    init() {
        super.init(frame: .zero)
        addSubview(main.scrollView)
        addSubview(frozen.scrollView)
        frozen.scrollView.isHidden = true
        frozen.scrollView.wheelTarget = main.scrollView
        main.scrollView.onTile = { [weak self] in
            self?.layoutFrozenPane()
            self?.controller?.updateFittingHeight()
        }
        observeScrolling()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        if main.scrollView.frame != bounds {
            main.scrollView.frame = bounds
        }
        controller?.containerDidLayout()
        layoutFrozenPane()
    }

    // Under legacy scrollers the frozen pane stops above the main pane's horizontal scroller, so both clips are one height.
    func layoutFrozenPane() {
        let width = min(frozenPaneWidth, bounds.width)
        frozen.scrollView.isHidden = width <= 0
        guard width > 0 else { return }
        let height = max(0, bounds.height - main.scrollView.legacyHorizontalScrollerHeight)
        let frame = NSRect(x: 0, y: 0, width: width, height: height)
        if frozen.scrollView.frame != frame {
            frozen.scrollView.frame = frame
        }
        syncVertical(from: main.scrollView, to: frozen.scrollView)
    }

    func pane(of tableView: NSTableView) -> DataGridPane? {
        if tableView === main.tableView { return main }
        if tableView === frozen.tableView { return frozen }
        return nil
    }

    func pane(_ kind: DataGridPane.Kind) -> DataGridPane {
        kind == .main ? main : frozen
    }

    // The pane under a point in this view's coordinates.
    func pane(at point: NSPoint) -> DataGridPane {
        if !frozen.scrollView.isHidden, frozen.scrollView.frame.contains(point) {
            return frozen
        }
        return main
    }

    // MARK: - Vertical sync

    private func observeScrolling() {
        let center = NotificationCenter.default
        let mainClip = main.scrollView.contentView
        let frozenClip = frozen.scrollView.contentView
        scrollObservers = [
            center.addObserver(forName: NSView.boundsDidChangeNotification, object: mainClip, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.syncVertical(from: self.main.scrollView, to: self.frozen.scrollView)
                    self.controller?.mainViewportDidMove()
                }
            },
            center.addObserver(forName: NSView.boundsDidChangeNotification, object: frozenClip, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.syncVertical(from: self.frozen.scrollView, to: self.main.scrollView)
                }
            },
            center.addObserver(forName: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.needsLayout = true }
            },
        ]
    }

    // clipView.scroll(to:) is right here: only y moves, so the header clip, which follows x, never drifts.
    private func syncVertical(from source: NSScrollView, to target: NSScrollView) {
        guard !isSyncingScroll, !target.isHidden || target === main.scrollView else { return }
        let y = source.contentView.bounds.origin.y
        let clip = target.contentView
        guard clip.bounds.origin.y != y else { return }
        isSyncingScroll = true
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
        target.reflectScrolledClipView(clip)
        isSyncingScroll = false
    }

    private func observePageScroll() {
        if let pageScrollObserver {
            NotificationCenter.default.removeObserver(pageScrollObserver)
        }
        pageScrollObserver = nil
        guard followsPageScroll, window != nil, let clip = enclosingScrollView?.contentView else { return }
        pageScrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clip,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.controller?.mainViewportDidMove() }
        }
    }

    func tearDown() {
        scrollObservers.forEach(NotificationCenter.default.removeObserver)
        scrollObservers.removeAll()
        followsPageScroll = false
        stopObservingWindow()
    }

    // MARK: - Focus

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObservingWindow()
        observePageScroll()
        guard let window else {
            refreshFocus()
            return
        }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshFocus() }
            })
        }
        // AppKit posts no first-responder notification but does notify KVO by hand.
        firstResponderObservation = window.observe(\.firstResponder, options: [.initial, .new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refreshFocus() }
        }
        controller?.containerDidMoveToWindow()
    }

    private func stopObservingWindow() {
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers.removeAll()
        firstResponderObservation = nil
    }

    // The main table or a field editor inside either pane holds focus, in the key window.
    func refreshFocus() {
        let hasFocus: Bool
        if let window, window.isKeyWindow, let responder = window.firstResponder as? NSView {
            hasFocus = responder === main.tableView || responder.isDescendant(of: self)
        } else {
            hasFocus = false
        }
        guard hasFocus != gridHasFocus else { return }
        gridHasFocus = hasFocus
        controller?.gridFocusDidChange()
    }

    // MARK: - Accessibility

    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        guard let window, !frozen.scrollView.isHidden else { return super.accessibilityHitTest(point) }
        let local = convert(window.convertPoint(fromScreen: point), from: nil)
        guard frozen.scrollView.frame.contains(local) else { return super.accessibilityHitTest(point) }
        return controller?.accessibilityElement(atFrozenPanePoint: frozen.tableView.convert(local, from: self))
            ?? super.accessibilityHitTest(point)
    }
}
