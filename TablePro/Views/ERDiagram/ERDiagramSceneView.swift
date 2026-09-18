//
//  ERDiagramSceneView.swift
//  TablePro
//
//  The diagram's drawing surface and the owner of every pointer event on it, as an AppKit view.
//
//  A `Canvas` cannot survive `NSScrollView.magnification`: measured on macOS 26, once the
//  accumulated scale reaches 0.5 SwiftUI truncates the Canvas's own drawing region to
//  `contentSize * magnification + 128` document points and hands the renderer that as its
//  `clipBoundingRect`, so everything past it is never drawn. A schema large enough to fit at 41%
//  therefore opened with a hard vertical and horizontal edge across it (#2692). Nothing configures
//  that away: `rendersAsynchronously`, `.drawingGroup()` and `preparedContentRect` were all
//  measured and none of them changes it.
//
//  AppKit paints a plain view at every magnification, sets its layer's `contentsScale` from the
//  magnification so text stays crisp when zoomed in, and tiles the backing store to the visible
//  rect.
//
//  Clicks, hover and drags are handled here as well, not by SwiftUI gestures. SwiftUI inside a
//  magnified scroll view reports every location in unscaled space: measured on macOS 27, at 50% a
//  click on the table drawn at document point (950, 650) arrived as (475, 325), so the diagram
//  selected, hovered and dragged whatever sat at half the pointer's position. `convert(_:from:)`
//  accounts for the clip view's scale, so every point handed on here is the one under the pointer.
//

import AppKit

/// Everything the canvas can ask of the diagram, in one place, so the view that owns the pointer
/// never reaches into a model of its own.
struct ERDiagramCanvasActions {
    let nodeAt: (CGPoint) -> UUID?
    let select: (UUID?) -> Void
    let beginDrag: (CGPoint) -> Void
    let updateDrag: (CGSize, CGPoint) -> Void
    let endDrag: () -> Void
    let scrollBy: (CGSize) -> Void
    let copyImage: () -> Void
}

final class ERDiagramSceneView: NSView {
    /// Once a client has asked for the tables, it holds their elements and reads a frame straight
    /// from one without asking for the children again, so a moved table has to update the element it
    /// already has. Before anyone asks, the rebuild waits for the first question.
    var scene = ERDiagramScene() {
        didSet {
            needsDisplay = true
            accessibilityTree.invalidate()
            if accessibilityTree.hasBeenAsked {
                _ = accessibilityTree.elements(for: scene, owner: self)
            }
            announceSelectionChange(from: oldValue.selectedNodeId)
        }
    }

    var actions: ERDiagramCanvasActions?

    private struct Press {
        let documentStart: CGPoint
        let windowStart: CGPoint
        var lastWindowPoint: CGPoint
        let nodeId: UUID?
        var isDragging = false
    }

    /// The distance the SwiftUI drag gesture waited for, so a click that wobbles by a point still
    /// selects the table instead of starting a drag.
    private static let dragThreshold: CGFloat = 2

    private var press: Press?
    private var isShowingHandCursor = false
    private let accessibilityTree = ERDiagramAccessibilityTree()

    override var isFlipped: Bool { true }

    override var isOpaque: Bool { false }

    /// Taking focus is what puts the diagram's scroll view on the responder chain, so View > Zoom
    /// In and Edit > Copy act on the diagram rather than on the window's fallbacks.
    override var acceptsFirstResponder: Bool { true }

    /// Cursor rects do not fire for a view mounted under SwiftUI, which this one is, so the hand
    /// pointer comes from a tracking area, the way `ResizeCursorSplitViewController` sets its own.
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        ERDiagramSceneRenderer.draw(scene, dirtyRect: dirtyRect, in: context)
    }

    /// An ER diagram tab has nothing else to type into, so the canvas takes focus when nothing holds
    /// it, the same claim the SQL editor makes. A tab switch mounts the canvas in the same update that
    /// removes the outgoing tab, measured, so the editor it replaces still holds focus on arrival and
    /// leaves the window holding it a moment later. The claim is asked again on the next turn.
    /// A tab or connection switch takes the canvas out of its window mid-drag, and a view that has
    /// left its window never gets the mouse-up, measured. Without this the drag and its auto-pan
    /// outlived the canvas and scrolled the diagram on their own once it came back.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        guard newWindow == nil, let press else { return }
        self.press = nil
        if press.isDragging {
            actions?.endDrag()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !claimFocusIfUnheld() else { return }
        DispatchQueue.main.async { [weak self] in
            self?.claimFocusIfUnheld()
        }
    }

    @discardableResult
    private func claimFocusIfUnheld() -> Bool {
        guard let window, window.firstResponder == nil || window.firstResponder === window else { return false }
        return window.makeFirstResponder(self)
    }

    @objc func copy(_ sender: Any?) {
        actions?.copyImage()
    }

    // MARK: - Pointer

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        press = Press(
            documentStart: point,
            windowStart: event.locationInWindow,
            lastWindowPoint: event.locationInWindow,
            nodeId: actions?.nodeAt(point)
        )
    }

    /// AppKit keeps sending a drag to the view that took the press wherever the pointer goes, so a
    /// drag carried past the window's edge still arrives here.
    override func mouseDragged(with event: NSEvent) {
        guard var press, let actions else { return }
        let windowPoint = event.locationInWindow

        if !press.isDragging {
            let travelled = hypot(windowPoint.x - press.windowStart.x, windowPoint.y - press.windowStart.y)
            guard travelled >= Self.dragThreshold else { return }
            press.isDragging = true
            actions.beginDrag(press.documentStart)
            if press.nodeId != nil {
                showHandCursor(.closedHand)
            }
        }

        if press.nodeId != nil {
            let current = convert(windowPoint, from: nil)
            actions.updateDrag(
                CGSize(width: current.x - press.documentStart.x, height: current.y - press.documentStart.y),
                current
            )
        } else {
            actions.scrollBy(panDelta(from: press.lastWindowPoint, to: windowPoint))
        }

        press.lastWindowPoint = windowPoint
        self.press = press
    }

    override func mouseUp(with event: NSEvent) {
        guard let press else { return }
        self.press = nil
        if press.isDragging {
            actions?.endDrag()
        } else {
            actions?.select(press.nodeId)
        }
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        guard press == nil else { return }
        restoreCursor()
    }

    /// A scroll or a zoom moves the tables under a still pointer and sends no `mouseMoved`, but
    /// AppKit does send this, and its default would put the arrow back over a table.
    override func cursorUpdate(with event: NSEvent) {
        guard press == nil else { return }
        guard isOverTable(convert(event.locationInWindow, from: nil)) else {
            NSCursor.arrow.set()
            isShowingHandCursor = false
            return
        }
        showHandCursor(.openHand)
    }

    /// Read in window points, because the document moves under a still pointer while it pans, then
    /// divided by the zoom to reach the document units the clip view scrolls in. Window points grow
    /// upward and this view grows downward, hence the two signs.
    private func panDelta(from previous: CGPoint, to current: CGPoint) -> CGSize {
        let magnification = max(enclosingScrollView?.magnification ?? 1, 0.01)
        return CGSize(
            width: (previous.x - current.x) / magnification,
            height: (current.y - previous.y) / magnification
        )
    }

    private func updateCursor(at point: CGPoint) {
        guard press == nil else { return }
        guard isOverTable(point) else {
            restoreCursor()
            return
        }
        showHandCursor(.openHand)
    }

    /// A drag released past the canvas edge leaves the table under a document point that is not on
    /// screen, and no exit follows to take the hand away again.
    private func isOverTable(_ point: CGPoint) -> Bool {
        visibleRect.contains(point) && actions?.nodeAt(point) != nil
    }

    private func showHandCursor(_ cursor: NSCursor) {
        cursor.set()
        isShowingHandCursor = true
    }

    private func restoreCursor() {
        guard isShowingHandCursor else { return }
        NSCursor.arrow.set()
        isShowingHandCursor = false
    }

    // MARK: - Accessibility

    /// The diagram is a canvas of tables rather than one picture, so it is published as a layout
    /// area with an element per table. Nothing is mounted for it: a plain `NSView` publishes
    /// `NSAccessibilityElement` children directly, which is the part of the data grid's rule that
    /// does not generalise (`NSTableView` builds its cell tree from cell views alone, and this is
    /// not a table view).
    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? { .layoutArea }

    override func accessibilityLabel() -> String? {
        ERDiagramAccessibilityTree.summary(of: scene)
    }

    override func accessibilityChildren() -> [Any]? {
        accessibilityTree.elements(for: scene, owner: self)
    }

    override func accessibilitySelectedChildren() -> [Any]? {
        selectedElement.map { [$0] } ?? []
    }

    /// A layout area answers for its focus as well as its selection, or VoiceOver never moves to
    /// the table a click just selected.
    override var accessibilityFocusedUIElement: Any? {
        selectedElement ?? self
    }

    private var selectedElement: ERDiagramNodeElement? {
        guard let selected = scene.selectedNodeId else { return nil }
        _ = accessibilityTree.elements(for: scene, owner: self)
        return accessibilityTree.element(for: selected)
    }

    private func announceSelectionChange(from previous: UUID?) {
        guard accessibilityTree.hasBeenAsked, previous != scene.selectedNodeId else { return }
        NSAccessibility.post(element: self, notification: .selectedChildrenChanged)
        guard let element = selectedElement else { return }
        NSAccessibility.post(element: element, notification: .focusedUIElementChanged)
    }
}
