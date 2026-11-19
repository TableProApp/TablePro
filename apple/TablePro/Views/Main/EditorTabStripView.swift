//
//  EditorTabStripView.swift
//  TablePro
//

import AppKit
import Combine

// AppKit on purpose: the scroll view, the drag session and the tab group element are what the system bar is built from.
@MainActor
internal final class EditorTabStripView: NSView {
    internal var commands: EditorTabCommands?

    internal private(set) var items: [EditorTabItem] = []
    internal private(set) var run = EditorTabRunLayout(viewportWidth: 0, count: 0)
    internal private(set) var reorder: EditorTabReorder?
    internal private(set) var hoveredId: UUID?

    internal let newTabButton = NSButton()
    internal let scrollView = EditorTabScrollView()

    private let track = EditorTabTrackView()
    private let document = EditorTabDocumentView()
    private var itemViews: [UUID: EditorTabItemView] = [:]
    private var lastActivatedId: UUID?
    private var dragHasLeftStrip = false
    private var dragWasCancelled = false
    private var dragCancelMonitor: Any?
    private var incomingIndex: Int?
    private var hoverArea: NSTrackingArea?
    private var laidOutWidth: CGFloat = 0
    private var windowSubscriptions: Set<AnyCancellable> = []
    private var chromeSubscriptions: Set<AnyCancellable> = []

    override internal init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    @available(*, unavailable)
    internal required init?(coder: NSCoder) {
        fatalError("EditorTabStripView does not support NSCoder init")
    }

    override internal var isFlipped: Bool { true }

    private func configure() {
        addSubview(track)

        // A scroll view in the titlebar would otherwise inset its content for the titlebar it sits in.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsetsZero
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.horizontalScrollElasticity = .automatic
        scrollView.verticalScrollElasticity = .none
        scrollView.documentView = document
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = EditorTabStripLayout.tabHeight / 2
        scrollView.layer?.cornerCurve = .continuous
        scrollView.layer?.masksToBounds = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        addSubview(scrollView)

        let symbol = NSImage.SymbolConfiguration(pointSize: EditorTabStripLayout.newTabGlyphSize, weight: .medium)
        newTabButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: String(localized: "New Tab"))?
            .withSymbolConfiguration(symbol)
        newTabButton.imagePosition = .imageOnly
        newTabButton.target = self
        newTabButton.action = #selector(newTabClicked)
        newTabButton.toolTip = String(localized: "New Tab")
        newTabButton.setAccessibilityLabel(String(localized: "New Tab"))
        if #available(macOS 26.0, *) {
            newTabButton.bezelStyle = .glass
            newTabButton.borderShape = .circle
        } else {
            newTabButton.bezelStyle = .circular
        }
        addSubview(newTabButton)

        registerForDraggedTypes([.editorTab])

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipBoundsChanged),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        AppEvents.shared.themeChanged
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.track.needsDisplay = true }
            }
            .store(in: &chromeSubscriptions)
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.track.needsDisplay = true }
            }
            .store(in: &chromeSubscriptions)
    }

    private var canAnimate: Bool {
        window?.isVisible == true && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    // MARK: - Content

    internal func apply(_ newItems: [EditorTabItem]) {
        guard newItems != items else { return }
        let previousIds = items.map(\.id)
        let previousSelection = items.first(where: \.isSelected)?.id
        items = newItems

        let liveIds = Set(newItems.map(\.id))
        for (id, view) in itemViews where !liveIds.contains(id) {
            view.removeFromSuperview()
            itemViews[id] = nil
        }
        if hoveredId.map({ !liveIds.contains($0) }) == true { hoveredId = nil }
        reconcileReorder(keeping: newItems.map(\.id))

        var inserted: Set<UUID> = []
        for item in newItems {
            if let view = itemViews[item.id] {
                view.apply(item)
            } else {
                let view = EditorTabItemView(item: item)
                view.strip = self
                view.isWindowActive = isWindowKey
                document.addSubview(view)
                itemViews[item.id] = view
                inserted.insert(item.id)
            }
        }

        let structureChanged = previousIds != newItems.map(\.id)
        layoutTabs(animated: structureChanged && !previousIds.isEmpty, inserted: inserted)

        let selection = newItems.first(where: \.isSelected)?.id
        if let selection, selection != previousSelection || structureChanged {
            reveal(selection, animated: true)
        }
    }

    private func reconcileReorder(keeping ids: [UUID]) {
        guard var live = reorder else { return }
        guard live.removingClosedTabs(keeping: ids), Set(live.order) == Set(ids) else {
            reorder = nil
            return
        }
        reorder = live
    }

    // The order the strip draws: nil marks the slot a tab arriving from another window will take.
    private var slots: [UUID?] {
        var ids: [UUID?] = reorder?.order ?? items.map(\.id)
        if dragHasLeftStrip, let dragged = reorder?.draggedId {
            ids.removeAll { $0 == dragged }
        }
        if let incomingIndex {
            ids.insert(nil, at: min(incomingIndex, ids.count))
        }
        return ids
    }

    // MARK: - Layout

    override internal func layout() {
        super.layout()
        let metrics = EditorTabStripLayout.self
        let buttonX = bounds.width - metrics.stripInset - metrics.newTabButtonSize
        newTabButton.frame = CGRect(x: buttonX, y: 0, width: metrics.newTabButtonSize, height: metrics.trackHeight)
        let trackFrame = CGRect(
            x: metrics.stripInset,
            y: 0,
            width: max(buttonX - metrics.trackSpacing - metrics.stripInset, 0),
            height: metrics.trackHeight
        )
        track.frame = trackFrame
        // Not `insetBy`: the band starts 1pt wide, and insetting an empty rect returns the null rect at infinity.
        scrollView.frame = CGRect(
            x: trackFrame.minX + metrics.trackPadding,
            y: metrics.trackPadding,
            width: max(trackFrame.width - metrics.trackPadding * 2, 0),
            height: metrics.tabHeight
        )
        layoutTabs(animated: false)
        refreshHoverArea()

        // The band is built collapsed, so the selection can only be revealed once it has a width.
        guard scrollView.bounds.width != laidOutWidth else { return }
        laidOutWidth = scrollView.bounds.width
        if let selection = items.first(where: \.isSelected)?.id {
            reveal(selection, animated: false)
        }
    }

    private func layoutTabs(animated: Bool, inserted: Set<UUID> = []) {
        let slots = slots
        run = EditorTabRunLayout(viewportWidth: scrollView.bounds.width, count: slots.count)
        document.setFrameSize(NSSize(
            width: max(run.contentWidth, scrollView.bounds.width),
            height: EditorTabStripLayout.tabHeight
        ))
        let frames = run.frames(offset: scrollView.contentView.bounds.minX)
        let shouldAnimate = animated && canAnimate

        let place = {
            for (index, slot) in slots.enumerated() {
                guard let id = slot, let view = self.itemViews[id] else { continue }
                if shouldAnimate, inserted.contains(id) {
                    view.frame = CGRect(x: frames[index].minX, y: 0, width: 0, height: frames[index].height)
                }
                if shouldAnimate {
                    view.animator().frame = frames[index]
                } else {
                    view.frame = frames[index]
                }
            }
        }
        updateSeparators()

        guard shouldAnimate else {
            place()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = EditorTabStripLayout.motionDuration
            context.timingFunction = EditorTabStripLayout.motionTiming
            place()
        }
    }

    private func updateSeparators() {
        let ids = slots.compactMap { $0 }
        let selectedId = items.first(where: \.isSelected)?.id
        for (index, id) in ids.enumerated() {
            itemViews[id]?.showsLeadingSeparator = EditorTabStripLayout.showsSeparator(
                before: index,
                tabIds: ids,
                selectedId: selectedId,
                hoveredId: hoveredId,
                isReordering: reorder != nil
            )
        }
    }

    @objc
    private func clipBoundsChanged() {
        guard run.maximumOffset > 0 else { return }
        layoutTabs(animated: false)
        updateHover()
    }

    internal func reveal(_ id: UUID, animated: Bool) {
        guard scrollView.bounds.width > 0, let index = slots.firstIndex(of: id) else { return }
        let clip = scrollView.contentView
        let target = run.revealOffset(forTabAt: index, from: clip.bounds.minX)
        guard target != clip.bounds.minX else { return }
        let origin = NSPoint(x: target, y: clip.bounds.minY)
        if animated, canAnimate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = EditorTabStripLayout.motionDuration
                context.timingFunction = EditorTabStripLayout.motionTiming
                clip.animator().setBoundsOrigin(origin)
            }
        } else {
            clip.setBoundsOrigin(origin)
        }
        scrollView.reflectScrolledClipView(clip)
    }

    // MARK: - Activation

    internal func activate(_ id: UUID, click: EditorTabClick?) {
        guard let commands else { return }
        let activation = EditorTabActivationResolver.resolve(
            click: click,
            tabId: id,
            lastActivatedTabId: lastActivatedId
        )
        lastActivatedId = id
        commands.activate(id)
        if activation == .selectAndKeep {
            commands.keepOpen(id)
        }
    }

    @objc
    private func newTabClicked() {
        commands?.newTab()
    }

    internal func moveFocus(from view: EditorTabItemView, by offset: Int) {
        guard let index = items.firstIndex(where: { $0.id == view.item.id }) else { return }
        let target = index + offset
        guard items.indices.contains(target), let next = itemViews[items[target].id] else { return }
        reveal(next.item.id, animated: true)
        window?.makeFirstResponder(next)
    }

    internal func itemView(for id: UUID) -> EditorTabItemView? {
        itemViews[id]
    }

    // MARK: - Hover and window state

    private func refreshHoverArea() {
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: scrollView.frame,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .mouseMoved],
            owner: self
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override internal func mouseEntered(with event: NSEvent) { updateHover() }
    override internal func mouseMoved(with event: NSEvent) { updateHover() }
    override internal func mouseExited(with event: NSEvent) { setHovered(nil) }

    // The run moves under a pointer that did not, so scrolling has to ask again as well.
    private func updateHover() {
        guard let window, window.isKeyWindow, reorder == nil else {
            setHovered(nil)
            return
        }
        let point = document.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let inside = scrollView.contentView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard scrollView.contentView.bounds.contains(inside) else {
            setHovered(nil)
            return
        }
        setHovered(itemViews.values.first { $0.frame.contains(point) }?.item.id)
    }

    private func setHovered(_ id: UUID?) {
        guard hoveredId != id else { return }
        if let hoveredId { itemViews[hoveredId]?.isHovered = false }
        hoveredId = id
        if let id { itemViews[id]?.isHovered = true }
        updateSeparators()
    }

    private var isWindowKey: Bool {
        window?.isKeyWindow ?? false
    }

    override internal func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowSubscriptions.removeAll()
        updateWindowState()
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.publisher(for: name, object: window)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateWindowState() }
                }
                .store(in: &windowSubscriptions)
        }
    }

    private func updateWindowState() {
        let isKey = isWindowKey
        itemViews.values.forEach { $0.isWindowActive = isKey }
        newTabButton.contentTintColor = isKey ? .secondaryLabelColor : .tertiaryLabelColor
        if !isKey { setHovered(nil) }
    }

    override internal func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        track.needsDisplay = true
        itemViews.values.forEach { $0.needsDisplay = true }
    }

    // MARK: - Dragging out

    internal func beginDrag(of view: EditorTabItemView, with event: NSEvent) {
        guard let commands else { return }
        let id = view.item.id
        setHovered(nil)

        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(id.uuidString, forType: .editorTab)
        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        draggingItem.setDraggingFrame(view.bounds, contents: view.dragImage())

        let session = view.beginDraggingSession(with: [draggingItem], event: event, source: view)
        session.draggingFormation = .none
        // A tab that will open its own window where it lands has nowhere to slide back to.
        session.animatesToStartingPositionsOnCancelOrFail = !commands.canTearOff(id)

        let pinned = Set(items.filter(\.isPinned).map(\.id))
        reorder = EditorTabReorder(draggedId: id, order: items.map(\.id), pinnedIds: pinned)
        dragHasLeftStrip = false
        view.alphaValue = 0
        layoutTabs(animated: false)
        watchForDragCancel()
    }

    // A drag session reports Escape and a release on empty space the same way, so the key is latched as it arrives.
    private func watchForDragCancel() {
        dragWasCancelled = false
        dragCancelMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let isEscape = event.keyCode == KeyCode.escape.rawValue
            MainActor.assumeIsolated {
                if isEscape { self?.dragWasCancelled = true }
            }
            return event
        }
    }

    private func stopWatchingForDragCancel() {
        guard let dragCancelMonitor else { return }
        NSEvent.removeMonitor(dragCancelMonitor)
        self.dragCancelMonitor = nil
    }

    internal func dragDidEnd(of view: EditorTabItemView, at screenPoint: NSPoint, operation: NSDragOperation) {
        let id = view.item.id
        let wasCancelled = dragWasCancelled || NSEvent.pressedMouseButtons & 1 != 0
        stopWatchingForDragCancel()
        reorder = nil
        dragHasLeftStrip = false
        view.alphaValue = 1
        layoutTabs(animated: true)

        guard let commands, EditorTabDragEnding.opensNewWindow(
            operation: operation,
            wasCancelled: wasCancelled,
            isOverTabStrip: commands.isOverTabStrip(screenPoint),
            canTearOff: commands.canTearOff(id)
        ) else { return }
        commands.tearOff(id, screenPoint)
    }

    // MARK: - Dragging in

    override internal func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override internal func wantsPeriodicDraggingUpdates() -> Bool { true }

    override internal func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let source = sender.draggingSource as? EditorTabItemView else { return [] }
        let isOwnTab = source.strip === self
        guard isOwnTab || accepts(source) else { return [] }
        autoscroll(towards: sender.draggingLocation)
        let location = run.slotLocation(
            ofContentX: document.convert(sender.draggingLocation, from: nil).x,
            offset: scrollView.contentView.bounds.minX
        )
        if isOwnTab {
            updateReorder(toLocation: location)
        } else {
            updateIncoming(toLocation: location)
        }
        return .move
    }

    override internal func draggingExited(_ sender: NSDraggingInfo?) {
        guard let source = sender?.draggingSource as? EditorTabItemView else { return }
        if source.strip === self {
            dragHasLeftStrip = true
        } else {
            incomingIndex = nil
        }
        layoutTabs(animated: true)
    }

    override internal func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let source = sender.draggingSource as? EditorTabItemView, let commands else { return false }
        if source.strip === self {
            guard let reorder, reorder.movedFromOriginal, let destination = reorder.destinationIndex else {
                return true
            }
            // The manager publishes a turn later, and the tab must not slide back in the meantime.
            let byId = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
            items = reorder.order.compactMap { byId[$0] }
            commands.moveTab(reorder.draggedId, destination)
            return true
        }
        defer {
            incomingIndex = nil
            layoutTabs(animated: true)
        }
        guard accepts(source), let index = incomingIndex else { return false }
        return commands.receiveTab(source.item.id, index)
    }

    private func accepts(_ source: EditorTabItemView) -> Bool {
        guard let commands, let sourceCommands = source.strip?.commands else { return false }
        return sourceCommands.connectionId == commands.connectionId && sourceCommands.canTearOff(source.item.id)
    }

    private func updateReorder(toLocation location: CGFloat) {
        guard var live = reorder, let current = live.destinationIndex else { return }
        let wasOutside = dragHasLeftStrip
        dragHasLeftStrip = false
        if let destination = EditorTabReorderResolver.settledDestination(
            forLocation: location,
            tabWidth: run.tabWidth,
            currentIndex: current,
            count: live.order.count
        ) {
            live.move(to: destination)
        }
        guard live != reorder || wasOutside else { return }
        reorder = live
        layoutTabs(animated: true)
    }

    private func updateIncoming(toLocation location: CGFloat) {
        guard run.tabWidth > 0 else { return }
        // Before the gap opens the pointer picks the nearest boundary, after it the slot it is over.
        let index = incomingIndex == nil
            ? min(Int((location / run.tabWidth).rounded()), items.count)
            : EditorTabReorderResolver.destination(forLocation: location, tabWidth: run.tabWidth, count: run.count)
        guard index != incomingIndex else { return }
        incomingIndex = index
        layoutTabs(animated: true)
    }

    private func autoscroll(towards windowPoint: NSPoint) {
        guard run.maximumOffset > 0 else { return }
        let clip = scrollView.contentView
        let point = clip.convert(windowPoint, from: nil)
        var offset = clip.bounds.minX
        if point.x < clip.bounds.minX + EditorTabStripLayout.autoscrollMargin {
            offset -= EditorTabStripLayout.autoscrollStep
        } else if point.x > clip.bounds.maxX - EditorTabStripLayout.autoscrollMargin {
            offset += EditorTabStripLayout.autoscrollStep
        }
        let target = run.clamped(offset: offset)
        guard target != clip.bounds.minX else { return }
        clip.setBoundsOrigin(NSPoint(x: target, y: clip.bounds.minY))
        scrollView.reflectScrolledClipView(clip)
    }

    // MARK: - Accessibility

    override internal func isAccessibilityElement() -> Bool { true }
    override internal func accessibilityRole() -> NSAccessibility.Role? { .tabGroup }
    override internal func accessibilityLabel() -> String? { String(localized: "Editor Tabs") }

    override internal func accessibilityTabs() -> [Any]? {
        items.compactMap { itemViews[$0.id] }
    }
}

internal enum EditorTabDragEnding {
    internal static func opensNewWindow(
        operation: NSDragOperation,
        wasCancelled: Bool,
        isOverTabStrip: Bool,
        canTearOff: Bool
    ) -> Bool {
        operation.isEmpty && !wasCancelled && !isOverTabStrip && canTearOff
    }
}

internal final class EditorTabDocumentView: NSView {
    override internal var isFlipped: Bool { true }
    override internal var mouseDownCanMoveWindow: Bool { false }
}

internal final class EditorTabScrollView: NSScrollView {
    override internal var mouseDownCanMoveWindow: Bool { false }

    // A wheel mouse only reports the vertical axis, and this view only scrolls along the other one.
    override internal func scrollWheel(with event: NSEvent) {
        guard event.phase.isEmpty, event.momentumPhase.isEmpty,
              abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX)
        else {
            super.scrollWheel(with: event)
            return
        }
        let clip = contentView
        let maximum = max((documentView?.frame.width ?? 0) - clip.bounds.width, 0)
        let target = min(max(clip.bounds.minX - event.scrollingDeltaY, 0), maximum)
        clip.setBoundsOrigin(NSPoint(x: target, y: clip.bounds.minY))
        reflectScrolledClipView(clip)
    }
}

@MainActor
internal final class EditorTabTrackView: NSView {
    override internal var isFlipped: Bool { true }
    override internal var mouseDownCanMoveWindow: Bool { false }

    override internal func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        let highContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let themed = EditorTabStripPalette.isOverThemedBackdrop(highContrast: highContrast)
        EditorTabStripPalette.trackColor(overThemedBackdrop: themed).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()

        let hairline = EditorTabStripLayout.hairline
        let edge = NSBezierPath(
            roundedRect: bounds.insetBy(dx: hairline / 2, dy: hairline / 2),
            xRadius: radius,
            yRadius: radius
        )
        edge.lineWidth = hairline
        EditorTabStripPalette.trackEdgeColor.setStroke()
        edge.stroke()
    }
}
