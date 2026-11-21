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
    // The button's state now, not when the event being handled was queued.
    internal var isPrimaryButtonDown: () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 }

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
    private var renameSession: EditorTabRenameSession?
    private var renameClickMonitor: Any?
    private var pendingRenameId: UUID?

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
            // A closed tab refuses the name, a tab a database switch filtered out keeps it.
            if renameSession?.tabId == id { endRename(commit: true) }
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
        // A tab squeezed into the edge has no room left for its field.
        if let id = renameSession?.tabId,
           let width = itemViews[id]?.frame.width,
           width < EditorTabStripLayout.minimumContentWidth {
            endRename(commit: true)
        }
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
        // Tabs refuse first responder, so a click on one never ends an edit by itself.
        endRename(commit: true)
        let activation = EditorTabActivationResolver.resolve(
            click: click,
            tabId: id,
            lastActivatedTabId: lastActivatedId
        )
        lastActivatedId = id
        pendingRenameId = nil
        commands.activate(id)
        guard activation == .selectAndKeep else { return }
        // Only a table tab is ever a preview, so the double-click that keeps one names a query tab instead.
        if commands.canRename(id) {
            pendingRenameId = id
        } else {
            commands.keepOpen(id)
        }
    }

    // On the release, so a double-click that turns into a drag moves the tab instead.
    internal func releaseClick(on id: UUID) {
        guard pendingRenameId == id else { return }
        pendingRenameId = nil
        beginRename(id)
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

    // MARK: - Renaming

    internal func beginRename(_ id: UUID) {
        guard renameSession?.tabId != id else { return }
        endRename(commit: true)
        guard let commands, commands.canRename(id), let seed = commands.renameSeed(id),
              let window, let view = itemViews[id] else { return }
        reveal(id, animated: false)
        guard view.frame.width >= EditorTabStripLayout.minimumContentWidth else { return }

        let prior = window.firstResponder.map { Self.restorableResponder($0) }
        let field = view.beginRename(text: seed.text, placeholder: seed.placeholder, delegate: self)
        renameSession = EditorTabRenameSession(tabId: id, commit: commands.rename, priorResponder: prior)
        guard window.makeFirstResponder(field) else {
            renameSession = nil
            view.endRename()
            return
        }
        field.currentEditor()?.selectAll(nil)
        // `makeFirstResponder` can post a stray end notification, so the session listens only once it returns.
        renameSession?.isArmed = true
        watchForClickAway()
    }

    internal func endRename(commit: Bool, restoringFocus: Bool = true) {
        guard let session = renameSession else { return }
        renameSession = nil
        stopWatchingForClickAway()
        guard let view = itemViews[session.tabId] else { return }
        // Text an input method is still composing has posted no change yet, and resigning commits it into the field.
        let isComposing = (view.renameField?.currentEditor() as? NSTextView)?.hasMarkedText() == true
        if !commit { view.renameField?.abortEditing() }
        if restoringFocus { restoreFocus(to: session.priorResponder) }
        let text = view.endRename()
        guard commit, session.hasUserEdit || isComposing,
              let title = session.commit(session.tabId, text)
        else { return }
        view.showTitle(title)
    }

    private func restoreFocus(to prior: NSResponder?) {
        guard let window else { return }
        let isInWindow = prior === window || (prior as? NSView)?.window === window
        if let prior, isInWindow, window.makeFirstResponder(prior) { return }
        window.makeFirstResponder(nil)
    }

    // A field editor stands in for the control it edits, and only the control can take focus back.
    private static func restorableResponder(_ responder: NSResponder) -> NSResponder {
        guard let editor = responder as? NSTextView, editor.isFieldEditor,
              let control = editor.delegate as? NSControl else { return responder }
        return control
    }

    private func watchForClickAway() {
        stopWatchingForClickAway()
        renameClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] nsEvent in
            nonisolated(unsafe) let event = nsEvent
            MainActor.assumeIsolated { self?.renameSawClick(event) }
            return nsEvent
        }
    }

    private func stopWatchingForClickAway() {
        guard let renameClickMonitor else { return }
        NSEvent.removeMonitor(renameClickMonitor)
        self.renameClickMonitor = nil
    }

    // Chrome that takes no focus would leave the field editing under a click anywhere but the field.
    private func renameSawClick(_ event: NSEvent) {
        guard let id = renameSession?.tabId, let field = itemViews[id]?.renameField else { return }
        let point = field.convert(event.locationInWindow, from: nil)
        if event.window === window, field.bounds.contains(point) { return }
        endRename(commit: true)
    }

    private func isRenameField(_ object: Any?) -> Bool {
        guard let id = renameSession?.tabId, let field = itemViews[id]?.renameField else { return false }
        return (object as? NSTextField) === field
    }

    private func renameFieldEdited(_ notification: Notification) {
        guard isRenameField(notification.object) else { return }
        renameSession?.hasUserEdit = true
    }

    private func renameFieldEnded(_ notification: Notification) {
        guard renameSession?.isArmed == true, isRenameField(notification.object) else { return }
        // Focus already went where something else sent it, so it stays there.
        endRename(commit: true, restoringFocus: false)
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

    // A connection switch takes the strip out of the window with the field still editing.
    override internal func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { endRename(commit: true) }
        super.viewWillMove(toWindow: newWindow)
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
        if !isKey { endRename(commit: true) }
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
        pendingRenameId = nil
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
        stopWatchingForDragCancel()
        dragWasCancelled = false
        dragCancelMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            MainActor.assumeIsolated { self?.noteKeyDuringDrag(keyCode) }
            return event
        }
    }

    internal var isWatchingForDragCancel: Bool { dragCancelMonitor != nil }

    internal func noteKeyDuringDrag(_ keyCode: UInt16) {
        if keyCode == KeyCode.escape.rawValue { dragWasCancelled = true }
    }

    private func stopWatchingForDragCancel() {
        guard let dragCancelMonitor else { return }
        NSEvent.removeMonitor(dragCancelMonitor)
        self.dragCancelMonitor = nil
    }

    internal func dragDidEnd(of view: EditorTabItemView, at screenPoint: NSPoint, operation: NSDragOperation) {
        let id = view.item.id
        let wasCancelled = dragWasCancelled || isPrimaryButtonDown()
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

    // A drag handled only after its release runs no session, and an Escape still queued before the release cancels it.
    internal func beginDeferredDrag() {
        pendingRenameId = nil
        watchForDragCancel()
    }

    // The release point settles a deferred drag as a session would have.
    internal func drop(_ view: EditorTabItemView, releasedAt screenPoint: NSPoint) {
        let wasCancelled = dragWasCancelled
        stopWatchingForDragCancel()
        guard let commands, !wasCancelled else { return }
        let id = view.item.id
        if let target = Self.strip(at: screenPoint), let targetWindow = target.window {
            target.settleDrop(of: view, atWindowPoint: targetWindow.convertPoint(fromScreen: screenPoint))
            return
        }
        guard EditorTabDragEnding.opensNewWindow(
            operation: [],
            wasCancelled: false,
            isOverTabStrip: commands.isOverTabStrip(screenPoint),
            canTearOff: commands.canTearOff(id)
        ) else { return }
        commands.tearOff(id, screenPoint)
    }

    internal func settleDrop(of source: EditorTabItemView, atWindowPoint point: NSPoint) {
        let location = slotLocation(atWindowPoint: point)
        guard source.strip === self else {
            guard accepts(source) else { return }
            updateIncoming(toLocation: location)
            _ = receive(source)
            return
        }
        let pinned = Set(items.filter(\.isPinned).map(\.id))
        reorder = EditorTabReorder(draggedId: source.item.id, order: items.map(\.id), pinnedIds: pinned)
        updateReorder(toLocation: location)
        commitReorder()
        reorder = nil
        layoutTabs(animated: true)
    }

    // The frontmost window at the point decides, as it would for a session's destination.
    private static func strip(at screenPoint: NSPoint) -> EditorTabStripView? {
        let number = NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: 0)
        guard let window = NSApp.window(withWindowNumber: number) else { return nil }
        return strip(in: window, atWindowPoint: window.convertPoint(fromScreen: screenPoint))
    }

    // The strip sits in the titlebar, outside the content view, so the hit test starts at the frame view.
    internal static func strip(in window: NSWindow, atWindowPoint point: NSPoint) -> EditorTabStripView? {
        var view = window.contentView?.superview?.hitTest(point)
        while let current = view, !(current is EditorTabStripView) {
            view = current.superview
        }
        return view as? EditorTabStripView
    }

    private func slotLocation(atWindowPoint point: NSPoint) -> CGFloat {
        run.slotLocation(
            ofContentX: document.convert(point, from: nil).x,
            offset: scrollView.contentView.bounds.minX
        )
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
        let location = slotLocation(atWindowPoint: sender.draggingLocation)
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
        guard let source = sender.draggingSource as? EditorTabItemView, commands != nil else { return false }
        if source.strip === self {
            commitReorder()
            return true
        }
        return receive(source)
    }

    private func commitReorder() {
        guard let commands, let reorder, reorder.movedFromOriginal, let destination = reorder.destinationIndex else {
            return
        }
        // The manager publishes a turn later, and the tab must not slide back in the meantime.
        let byId = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        items = reorder.order.compactMap { byId[$0] }
        commands.moveTab(reorder.draggedId, destination)
    }

    private func receive(_ source: EditorTabItemView) -> Bool {
        defer {
            incomingIndex = nil
            layoutTabs(animated: true)
        }
        guard let commands, accepts(source), let index = incomingIndex else { return false }
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

extension EditorTabStripView: NSTextFieldDelegate {
    // Fires on the first change the user makes, not on focus, which is what tells an edit from Return on an untouched name.
    internal func controlTextDidBeginEditing(_ obj: Notification) {
        renameFieldEdited(obj)
    }

    internal func controlTextDidChange(_ obj: Notification) {
        renameFieldEdited(obj)
    }

    internal func controlTextDidEndEditing(_ obj: Notification) {
        renameFieldEnded(obj)
    }

    // Left to AppKit, Return ends the edit and starts it again, and Escape ends nothing.
    internal func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard isRenameField(control) else { return false }
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)),
             #selector(NSResponder.insertTab(_:)),
             #selector(NSResponder.insertBacktab(_:)):
            endRename(commit: true)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            // `abortEditing` posts no end notification, so the cancel never comes back as a commit.
            control.abortEditing()
            endRename(commit: false)
            return true
        default:
            return false
        }
    }
}

// One edit per strip, for the tab it names.
private struct EditorTabRenameSession {
    let tabId: UUID
    // Held from the start, so a strip whose commands are cleared mid-edit can still hand the name over.
    let commit: (UUID, String) -> String?
    weak var priorResponder: NSResponder?
    var isArmed = false
    var hasUserEdit = false
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
