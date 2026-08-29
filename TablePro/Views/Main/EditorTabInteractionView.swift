//
//  EditorTabInteractionView.swift
//  TablePro
//

import AppKit
import SwiftUI

/// The single owner of pointer input over the editor tab strip.
///
/// It is the strip's superview rather than a view laid over it, which is what keeps the SwiftUI
/// tabs where accessibility already finds them: a view mounted *over* the track covers every tab in
/// the accessibility tree however little it draws, measured, which is why the Escape monitor this
/// replaces had to be a background. A parent adds no sibling and shadows nothing.
///
/// Two things follow from owning the press outright. `mouseDownCanMoveWindow` is false, so AppKit's
/// titlebar window drag can never take a gesture that started on a tab, at any position, on any
/// machine. And the click, the reorder and the tear-off are told apart inside one AppKit tracking
/// loop rather than by SwiftUI arbitrating between a `Button`, a `ScrollView` and a `DragGesture`,
/// which is what made a plain one-place drag do nothing about one time in seven.
///
/// The loop is the shape AppKit controls have always used: `nextEvent(matching:)` with periodic
/// events mixed in, which is the documented way to keep autoscrolling while the pointer is held
/// still at the edge of the track.
@MainActor
internal final class EditorTabInteractionView: NSView {
    internal let interaction: EditorTabStripInteraction

    /// Told to the pane controller, which publishes it as the band's height. A wrapped strip is
    /// taller, and the titlebar accessory has to grow with it or the extra rows are drawn behind
    /// the content.
    internal var onRowCountChanged: ((Int) -> Void)?

    private var isResolvingAccessibilityHit = false
    private var hoverTrackingArea: NSTrackingArea?
    private var lastActivatedTabId: UUID?

    internal init(interaction: EditorTabStripInteraction) {
        self.interaction = interaction
        super.init(frame: .zero)
        /// Every path that re-lays the run reports through here, not just this view's own layout.
        /// A tab opened or closed while the strip is wrapped can cross a row boundary, and that
        /// change arrives on the interaction rather than on a layout pass.
        interaction.onRowCountChanged = { [weak self] rows in
            self?.onRowCountChanged?(rows)
            self?.needsLayout = true
        }
    }

    @available(*, unavailable)
    internal required init?(coder: NSCoder) {
        fatalError("EditorTabInteractionView does not support NSCoder init")
    }

    /// The run layout, the SwiftUI drawing and this view's hit testing all measure y downward, so
    /// none of the three has to flip the other two.
    override internal var isFlipped: Bool { true }

    /// The strip never drags the window. The band around it keeps AppKit's default, so the empty
    /// chrome either side of the track still moves the window the way Finder's tab bar does.
    override internal var mouseDownCanMoveWindow: Bool { false }

    override internal func isAccessibilityElement() -> Bool { false }

    // MARK: - Geometry

    /// The track's viewport, which is everything the pointer owns. The new-tab button sits outside
    /// it and stays an ordinary SwiftUI button.
    internal var trackRect: CGRect {
        let trailing = EditorTabStripLayout.stripInset
            + EditorTabStripLayout.newTabButtonSize
            + EditorTabStripLayout.trackSpacing
        let width = max(bounds.width - EditorTabStripLayout.stripInset - trailing, 0)
        return CGRect(
            x: EditorTabStripLayout.stripInset,
            y: 0,
            width: width,
            height: EditorTabStripLayout.trackHeight(forRowCount: interaction.run.rowCount)
        )
    }

    private var viewportRect: CGRect {
        trackRect.insetBy(dx: EditorTabStripLayout.trackPadding, dy: EditorTabStripLayout.trackPadding)
    }

    private func contentPoint(from event: NSEvent) -> CGPoint {
        contentPoint(fromViewPoint: convert(event.locationInWindow, from: nil))
    }

    private func contentPoint(fromViewPoint point: CGPoint) -> CGPoint {
        CGPoint(
            x: point.x - viewportRect.minX + interaction.contentOffset,
            y: point.y - viewportRect.minY
        )
    }

    override internal func layout() {
        super.layout()
        rebuildRun()
        refreshHoverTracking()
    }

    /// Re-measures the run. The row count reaches the pane controller from the interaction, which
    /// is the one place every rebuild goes through.
    internal func rebuildRun() {
        interaction.updateRun(trackWidth: trackRect.width, count: interaction.tabIds.count)
        interaction.clampContentOffset()
    }

    // MARK: - Hit testing

    /// Claims the track and nothing else, so a press on a tab is this view's and a press on the
    /// new-tab button, on the band's insets or on the chrome below the track is not.
    ///
    /// The claim is for the pointer alone. Accessibility resolves a screen point through this same
    /// method, so claiming it unconditionally answered "the strip" for every tab and took all of
    /// them out of reach of VoiceOver, Switch Control, Voice Control and XCUITest at once: this
    /// view publishes nothing, so there was no element under a tab to speak, press or click. That
    /// shipped in #2571 and turned the whole UI suite red from the commit that merged it.
    override internal func hitTest(_ point: NSPoint) -> NSView? {
        guard !isResolvingAccessibilityHit else { return super.hitTest(point) }
        let local = convert(point, from: superview)
        guard trackRect.contains(local) else { return super.hitTest(point) }
        return self
    }

    /// Answers from the SwiftUI tree, which is where the tabs publish themselves. The pointer's
    /// claim is lifted for the length of the question.
    override internal func accessibilityHitTest(_ point: NSPoint) -> Any? {
        isResolvingAccessibilityHit = true
        defer { isResolvingAccessibilityHit = false }
        return super.accessibilityHitTest(point)
    }

    private func tabIndex(atViewPoint point: CGPoint) -> Int? {
        EditorTabRunLayoutBuilder.index(at: contentPoint(fromViewPoint: point), in: interaction.run)
    }

    private func tabId(at index: Int) -> UUID? {
        let ids = interaction.displayedIds
        guard ids.indices.contains(index) else { return nil }
        return ids[index]
    }

    private func isCloseButton(_ point: CGPoint, forTabAt index: Int) -> Bool {
        guard let placement = interaction.run.placement(at: index) else { return false }
        return EditorTabRunLayoutBuilder.closeButtonRect(in: placement.frame)
            .contains(contentPoint(fromViewPoint: point))
    }

    // MARK: - Hover

    private func refreshHoverTracking() {
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: trackRect,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .mouseMoved],
            owner: self
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override internal func mouseMoved(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override internal func mouseExited(with event: NSEvent) {
        interaction.setHovered(nil)
    }

    private func updateHover(at point: CGPoint) {
        guard let index = tabIndex(atViewPoint: point), let id = tabId(at: index) else {
            interaction.setHovered(nil)
            toolTip = nil
            return
        }
        interaction.setHovered(id, overCloseButton: isCloseButton(point, forTabAt: index))
        toolTip = interaction.commands?.tooltip(id)
    }

    // MARK: - Scrolling

    /// The track scrolls itself, because the view that owns the press owns the wheel too. A
    /// wrapped run never overflows, so it ignores this.
    override internal func scrollWheel(with event: NSEvent) {
        let delta = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY)
            ? event.scrollingDeltaX
            : event.scrollingDeltaY
        guard delta != 0 else { return }
        interaction.scroll(by: -delta)
        /// The run moved under a pointer that did not, so the tab it is over, its close target and
        /// the tooltip all changed. Without this the close affordance is drawn on one tab while a
        /// click in that slot hits another.
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    // MARK: - Contextual menu

    override internal func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = tabIndex(atViewPoint: point), let id = tabId(at: index),
              let commands = interaction.commands
        else { return nil }
        return EditorTabContextMenuBuilder.menu(for: id, commands: commands)
    }

    // MARK: - Tracking

    override internal func mouseDown(with event: NSEvent) {
        let start = convert(event.locationInWindow, from: nil)
        guard let index = tabIndex(atViewPoint: start), let pressedId = tabId(at: index) else { return }

        if isCloseButton(start, forTabAt: index) {
            trackCloseButton(startingAt: start, tabId: pressedId)
            return
        }

        activate(pressedId, click: EditorTabClick(event: event))
        trackDrag(startingAt: start, tabId: pressedId)
    }

    /// A press on the close button commits only if the pointer is still on it when the button comes
    /// up, which is what every AppKit button does and what lets a user change their mind.
    private func trackCloseButton(startingAt start: CGPoint, tabId: UUID) {
        guard let window else { return }
        var isInside = true
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let point = convert(next.locationInWindow, from: nil)
            if next.type == .leftMouseUp {
                if isInside, let index = interaction.displayedIds.firstIndex(of: tabId),
                   isCloseButton(point, forTabAt: index) {
                    interaction.commands?.close(tabId)
                }
                return
            }
            guard let index = interaction.displayedIds.firstIndex(of: tabId) else { return }
            isInside = isCloseButton(point, forTabAt: index)
        }
    }

    private func trackDrag(startingAt start: CGPoint, tabId: UUID) {
        guard let window else { return }
        var gesture: EditorTabGesture?
        NSEvent.startPeriodicEvents(afterDelay: 0.08, withPeriod: 0.02)
        defer { NSEvent.stopPeriodicEvents() }

        var latest = start
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .keyDown, .periodic]) {
            switch next.type {
            case .keyDown where next.keyCode == KeyCode.escape.rawValue:
                interaction.clearReorder()
                consumeRemainingDrag(in: window)
                return
            case .keyDown:
                /// Every key-down matches the mask, and taking one out of the queue without
                /// dispatching it would swallow `Cmd+W`, `Cmd+T` and the tab-switch shortcuts for
                /// as long as the button is held. The reorder already survives a tab opening or
                /// closing under it, so the commands stay live.
                NSApp.sendEvent(next)
            case .leftMouseUp:
                /// The release carries a location of its own, and a fast drag can cross a
                /// neighbour's midpoint between the last drag sample and it. Resolving from
                /// `latest` alone commits the order the pointer had a frame ago, which is the
                /// short-move-or-nothing this change exists to remove.
                latest = convert(next.locationInWindow, from: nil)
                gesture = resolveGesture(gesture, from: start, to: latest, tabId: tabId)
                if gesture == .reorder { applyReorder(at: latest, tabId: tabId) }
                finishDrag(gesture, tabId: tabId)
                return
            case .periodic:
                guard gesture == .reorder else { continue }
                autoscroll(towards: latest)
                applyReorder(at: latest, tabId: tabId)
            case .leftMouseDragged:
                latest = convert(next.locationInWindow, from: nil)
                gesture = resolveGesture(gesture, from: start, to: latest, tabId: tabId)
                guard gesture == .reorder else { continue }
                autoscroll(towards: latest)
                applyReorder(at: latest, tabId: tabId)
            default:
                continue
            }
        }
    }

    /// A press becomes a reorder once it travels the distance AppKit uses to tell a click from a
    /// drag, and a tear-off once it leaves the band by more than a tab's height again. A gesture
    /// never goes back to being a click.
    private func resolveGesture(
        _ current: EditorTabGesture?,
        from start: CGPoint,
        to point: CGPoint,
        tabId: UUID
    ) -> EditorTabGesture? {
        if canTearOff(tabId), abs(point.y - start.y) >= EditorTabStripLayout.tearOffThreshold {
            interaction.markTearingOff(tabId)
            return .tearOff
        }
        if current == .tearOff {
            interaction.markTearingOff(nil)
        }
        guard current == .reorder || hypot(point.x - start.x, point.y - start.y) >= EditorTabStripLayout.reorderThreshold
        else { return current }
        interaction.beginReorder(of: tabId)
        return .reorder
    }

    private func canTearOff(_ tabId: UUID) -> Bool {
        interaction.commands?.canTearOff(tabId) ?? false
    }

    private func applyReorder(at point: CGPoint, tabId: UUID) {
        let location = EditorTabRunLayoutBuilder.linearLocation(
            of: contentPoint(fromViewPoint: point),
            in: interaction.run
        )
        withMotion(.easeInOut(duration: 0.18)) {
            interaction.updateReorder(toLinearLocation: location)
        }
    }

    /// Scrolls the track while the pointer is held near either edge, so a tab can be dragged to a
    /// place that is not currently on screen. Without it a reorder stops at the viewport and the
    /// tabs a user opened first, the ones #2438 is about, cannot be reached at all.
    private func autoscroll(towards point: CGPoint) {
        guard interaction.overflow == .scroll else { return }
        let leadingEdge = viewportRect.minX + EditorTabStripLayout.autoscrollMargin
        let trailingEdge = viewportRect.maxX - EditorTabStripLayout.autoscrollMargin
        if point.x < leadingEdge {
            interaction.scroll(by: -EditorTabStripLayout.autoscrollStep)
        } else if point.x > trailingEdge {
            interaction.scroll(by: EditorTabStripLayout.autoscrollStep)
        }
    }

    private func finishDrag(_ gesture: EditorTabGesture?, tabId: UUID) {
        switch gesture {
        case .tearOff:
            interaction.markTearingOff(nil)
            interaction.clearReorder()
            interaction.commands?.tearOff(tabId)
        case .reorder:
            interaction.commitReorder()
        default:
            interaction.clearReorder()
        }
    }

    /// Escape abandons the drag, and the pointer is still down. Swallowing the rest of the gesture
    /// is what keeps the release from starting a fresh one.
    private func consumeRemainingDrag(in window: NSWindow) {
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { return }
        }
    }

    private func activate(_ tabId: UUID, click: EditorTabClick?) {
        guard let commands = interaction.commands else { return }
        let activation = EditorTabActivationResolver.resolve(
            click: click,
            tabId: tabId,
            lastActivatedTabId: lastActivatedTabId
        )
        lastActivatedTabId = tabId
        commands.activate(tabId)
        guard activation == .selectAndKeep else { return }
        commands.keepOpen(tabId)
    }
}
