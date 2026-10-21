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
import Combine

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
    var edgeAt: (CGPoint, CGFloat) -> UUID? = { _, _ in nil }
    var columnAt: (CGPoint) -> ERDiagramColumnHit? = { _ in nil }
    var selectEdge: (UUID?) -> Void = { _ in }
    var openTable: (UUID) -> Void = { _ in }
    var menuSections: (ERDiagramMenuTarget) -> [[ERDiagramMenuEntry]] = { _ in [] }
    var perform: (ERDiagramMenuCommand) -> Void = { _ in }
    var canDeleteSelection: () -> Bool = { false }
    var deleteSelection: () -> Bool = { false }
    var canLinkColumns: () -> Bool = { false }
    var canLink: (ERDiagramColumnHit, ERDiagramColumnHit) -> Bool = { _, _ in false }
    var linkColumns: (ERDiagramColumnHit, ERDiagramColumnHit) -> Void = { _, _ in }
}

final class ERDiagramSceneView: NSView, NSMenuItemValidation {
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
            // A table that moved or grew under a still pointer moves its column rows with it.
            hoveredColumn = nil
            if let lastHoverPoint, press == nil {
                updateHover(at: lastHoverPoint)
            }
        }
    }

    var actions: ERDiagramCanvasActions?

    private struct Press {
        let documentStart: CGPoint
        let windowStart: CGPoint
        var lastWindowPoint: CGPoint
        let nodeId: UUID?
        var edgeId: UUID?
        var link: ERDiagramColumnHit?
        var isDragging = false
    }

    private struct LinkDraft {
        let source: ERDiagramColumnHit
        var pointer: CGPoint
        var target: ERDiagramColumnHit?
    }

    // In screen points, divided by the zoom wherever they meet document units.
    private static let edgeHitTolerance: CGFloat = 5
    private static let handleRadius: CGFloat = 4.5
    private static let handleHitRadius: CGFloat = 8

    /// The distance the SwiftUI drag gesture waited for, so a click that wobbles by a point still
    /// selects the table instead of starting a drag.
    private static let dragThreshold: CGFloat = 2

    private var press: Press?
    private var hoveredColumn: ERDiagramColumnHit?
    private var lastHoverPoint: CGPoint?
    private var linkDraft: LinkDraft?
    private var isShowingHandCursor = false
    private let accessibilityTree = ERDiagramAccessibilityTree()
    private var bakedPalette: ERDiagramPalette?
    private var themeCancellable: AnyCancellable?

    var palette: ERDiagramPalette {
        if let bakedPalette { return bakedPalette }
        let baked = ERDiagramPalette(appearance: effectiveAppearance)
        bakedPalette = baked
        return baked
    }

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
        themeCancellable = AppEvents.shared.themeChanged
            .sink { [weak self] _ in self?.discardPalette() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let canvas = ERDiagramContextCanvas(context: context)
        ERDiagramSceneRenderer.draw(scene, palette: palette, dirtyRect: dirtyRect, on: canvas)
        drawLinkAffordances(on: canvas)
    }

    // Drawn by the view rather than the scene, so a hover or a drag in progress never reaches an export.
    private func drawLinkAffordances(on canvas: ERDiagramContextCanvas) {
        if let linkDraft {
            if let target = linkDraft.target {
                canvas.stroke(
                    CGPath(rect: target.rowRect, transform: nil),
                    color: palette.selectionRule,
                    lineWidth: 2,
                    rounded: false
                )
            }
            let line = CGMutablePath()
            line.move(to: handleCentre(of: linkDraft.source))
            line.addLine(to: linkDraft.target.map(handleCentre(of:)) ?? linkDraft.pointer)
            canvas.stroke(
                line.copy(dashingWithPhase: 0, lengths: [6 / magnification, 4 / magnification]),
                color: palette.selectionRule,
                lineWidth: 1.5 / magnification,
                rounded: true
            )
        }
        if let column = linkDraft?.source ?? hoveredColumn {
            let radius = Self.handleRadius / magnification
            let centre = handleCentre(of: column)
            let handle = CGPath(
                ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2),
                transform: nil
            )
            canvas.fill(handle, color: palette.selectionRule)
        }
    }

    private var magnification: CGFloat {
        max(enclosingScrollView?.magnification ?? 1, 0.01)
    }

    private func handleCentre(of column: ERDiagramColumnHit) -> CGPoint {
        CGPoint(x: column.rowRect.maxX, y: column.rowRect.midY)
    }

    private func handleBounds(of column: ERDiagramColumnHit) -> CGRect {
        let reach = Self.handleHitRadius / magnification
        let centre = handleCentre(of: column)
        return CGRect(x: centre.x - reach, y: centre.y - reach, width: reach * 2, height: reach * 2)
    }

    private func isOnHandle(_ point: CGPoint, of column: ERDiagramColumnHit) -> Bool {
        hypot(point.x - handleCentre(of: column).x, point.y - handleCentre(of: column).y)
            <= Self.handleHitRadius / magnification
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        discardPalette()
    }

    private func discardPalette() {
        bakedPalette = nil
        needsDisplay = true
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
        guard newWindow == nil else { return }
        hoveredColumn = nil
        linkDraft = nil
        guard let press else { return }
        self.press = nil
        if press.isDragging, press.link == nil {
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

    @objc func delete(_ sender: Any?) {
        if actions?.deleteSelection() != true {
            NSSound.beep()
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(delete(_:)):
            return actions?.canDeleteSelection() ?? false
        default:
            return true
        }
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch KeyCode(rawValue: event.keyCode) {
        case .delete where modifiers.isEmpty, .forwardDelete where modifiers.isEmpty:
            delete(nil)
        case .escape where linkDraft != nil:
            cancelLink()
        default:
            super.keyDown(with: event)
        }
    }

    private func cancelLink() {
        linkDraft = nil
        press = nil
        needsDisplay = true
    }

    // MARK: - Menus

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let actions, press == nil else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let target: ERDiagramMenuTarget
        if let column = actions.columnAt(point) {
            actions.select(column.nodeId)
            target = .column(table: column.tableName, column: column.columnName)
        } else if let nodeId = actions.nodeAt(point), let table = tableName(of: nodeId) {
            actions.select(nodeId)
            target = .table(table)
        } else if let edgeId = actions.edgeAt(point, Self.edgeHitTolerance / magnification) {
            actions.selectEdge(edgeId)
            target = .edge(edgeId)
        } else {
            actions.select(nil)
            target = .canvas(point)
        }
        return ERDiagramMenuBuilder.menu(
            sections: actions.menuSections(target),
            target: self,
            action: #selector(performMenuCommand(_:))
        )
    }

    // VoiceOver's Show Menu on a table or column element, opened over the element it was asked from.
    func showMenu(for target: ERDiagramMenuTarget, at rect: CGRect) {
        guard let actions,
              let menu = ERDiagramMenuBuilder.menu(
                  sections: actions.menuSections(target),
                  target: self,
                  action: #selector(performMenuCommand(_:))
              )
        else { return }
        menu.popUp(positioning: nil, at: CGPoint(x: rect.midX, y: rect.midY), in: self)
    }

    @objc private func performMenuCommand(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? ERDiagramMenuCommandBox else { return }
        actions?.perform(box.command)
    }

    private func tableName(of nodeId: UUID) -> String? {
        scene.nodes.first { $0.id == nodeId }?.tableName
    }

    // MARK: - Pointer

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        // Control-click is the secondary click, and this override would otherwise take it as a press.
        if event.modifierFlags.contains(.control) {
            if let menu = menu(for: event) {
                NSMenu.popUpContextMenu(menu, with: event, for: self)
            }
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        if let column = hoveredColumn, actions?.canLinkColumns() == true, isOnHandle(point, of: column) {
            press = Press(
                documentStart: point,
                windowStart: event.locationInWindow,
                lastWindowPoint: event.locationInWindow,
                nodeId: column.nodeId,
                link: column
            )
            return
        }
        updateHover(at: nil)
        let nodeId = actions?.nodeAt(point)
        press = Press(
            documentStart: point,
            windowStart: event.locationInWindow,
            lastWindowPoint: event.locationInWindow,
            nodeId: nodeId,
            edgeId: nodeId == nil ? actions?.edgeAt(point, Self.edgeHitTolerance / magnification) : nil
        )
    }

    /// AppKit keeps sending a drag to the view that took the press wherever the pointer goes, so a
    /// drag carried past the window's edge still arrives here.
    override func mouseDragged(with event: NSEvent) {
        guard var press, let actions else { return }
        let windowPoint = event.locationInWindow

        if let source = press.link {
            press.isDragging = true
            press.lastWindowPoint = windowPoint
            self.press = press
            updateLink(from: source, to: convert(windowPoint, from: nil))
            _ = autoscroll(with: event)
            return
        }

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
        let point = convert(event.locationInWindow, from: nil)
        if let source = press.link {
            let target = linkDraft?.target
            linkDraft = nil
            needsDisplay = true
            if press.isDragging, let target {
                actions?.linkColumns(source, target)
            } else if !press.isDragging {
                actions?.select(source.nodeId)
            }
        } else if press.isDragging {
            actions?.endDrag()
        } else if let nodeId = press.nodeId {
            actions?.select(nodeId)
            if event.clickCount == 2 {
                actions?.openTable(nodeId)
            }
        } else if let edgeId = press.edgeId {
            actions?.selectEdge(edgeId)
        } else {
            actions?.select(nil)
        }
        updateHover(at: point)
        updateCursor(at: point)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateHover(at: point)
        updateCursor(at: point)
    }

    private func updateLink(from source: ERDiagramColumnHit, to point: CGPoint) {
        let candidate = actions?.columnAt(point)
        let target = candidate.flatMap { actions?.canLink(source, $0) == true ? $0 : nil }
        linkDraft = LinkDraft(source: source, pointer: point, target: target)
        needsDisplay = true
    }

    private func updateHover(at point: CGPoint?) {
        if point != nil, press != nil { return }
        lastHoverPoint = point
        let next = point.flatMap(hoverTarget(at:))
        guard next != hoveredColumn else { return }
        if let previous = hoveredColumn {
            setNeedsDisplay(handleBounds(of: previous))
        }
        hoveredColumn = next
        if let next {
            setNeedsDisplay(handleBounds(of: next))
        }
    }

    // The handle sits on the table's edge, half outside it, so it stays up while the pointer is on it.
    private func hoverTarget(at point: CGPoint) -> ERDiagramColumnHit? {
        guard actions?.canLinkColumns() == true else { return nil }
        if let current = hoveredColumn, isOnHandle(point, of: current) {
            return current
        }
        return actions?.columnAt(point).flatMap { $0.canHoldKey ? $0 : nil }
    }

    override func mouseExited(with event: NSEvent) {
        guard press == nil else { return }
        updateHover(at: nil)
        restoreCursor()
    }

    /// A scroll or a zoom moves the tables under a still pointer and sends no `mouseMoved`, but
    /// AppKit does send this, and its default would put the arrow back over a table.
    override func cursorUpdate(with event: NSEvent) {
        guard press == nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let column = hoveredColumn, isOnHandle(point, of: column) {
            showHandCursor(.crosshair)
            return
        }
        guard isOverTable(point) else {
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
        if let column = hoveredColumn, isOnHandle(point, of: column) {
            showHandCursor(.crosshair)
            return
        }
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
