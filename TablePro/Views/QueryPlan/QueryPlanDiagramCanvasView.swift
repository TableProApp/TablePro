//
//  QueryPlanDiagramCanvasView.swift
//  TablePro
//
//  The plan diagram's document view. SwiftUI draws the steps and arrows; this view owns every
//  click, menu, popover and accessibility element on them.
//
//  SwiftUI inside a magnified scroll view hit-tests in unscaled space: measured on macOS 27, at 50%
//  a click on a step's drawn centre missed it, and a click on empty canvas twice as far from the
//  origin opened that step's popover. The layout's own rects, hit-tested through
//  `convert(_:from:)`, which accounts for the clip view's scale, find the step under the pointer at
//  every zoom.
//

import AppKit
import SwiftUI

final class QueryPlanDiagramCanvasView: NSView {
    private(set) var planLayout: QueryPlanDiagramLayout?
    private(set) var selectedNodeId: UUID?
    private var select: ((UUID?) -> Void)?

    /// Renders the export copy of the plan, which the SwiftUI view owns, onto the pasteboard.
    var copyImage: (() -> Void)?

    private var drawingHost: QueryPlanDiagramDrawingHost?
    private var nodeElements: [QueryPlanDiagramNodeElement] = []
    private var pressedNodeId: UUID?
    private var popover: NSPopover?
    private var popoverNodeId: UUID?

    override var isFlipped: Bool { true }

    /// Taking focus on a click is what puts the plan's scroll view on the responder chain, so View >
    /// Zoom In and Edit > Copy act on the plan instead of on the editor above it.
    override var acceptsFirstResponder: Bool { true }

    @objc func copy(_ sender: Any?) {
        copyImage?()
    }

    func update(layout: QueryPlanDiagramLayout, selectedNodeId: UUID?, select: @escaping (UUID?) -> Void) {
        let isNewPlan = self.planLayout?.nodes.map(\.id) != layout.nodes.map(\.id)
        self.planLayout = layout
        self.selectedNodeId = selectedNodeId
        self.select = select

        showDrawing(QueryPlanDiagramDrawing(layout: layout, selectedNodeId: selectedNodeId))
        if isNewPlan {
            rebuildNodeElements(for: layout)
        }
        nodeElements.forEach { $0.setAccessibilitySelected($0.nodeId == selectedNodeId) }
        syncPopover()
    }

    /// Paint order: the step drawn last is the one on top.
    func nodeId(at point: CGPoint) -> UUID? {
        planLayout?.nodes.last { $0.rect.contains(point) }?.id
    }

    /// Writing the selection it already holds never reaches `update`, so a click on the selected
    /// step asks for its details directly, which is what brings back a popover that could not show.
    func selectNode(_ nodeId: UUID) {
        guard nodeId != selectedNodeId else {
            syncPopover()
            return
        }
        select?(nodeId)
    }

    // MARK: - Drawing

    private func showDrawing(_ drawing: QueryPlanDiagramDrawing) {
        if let drawingHost {
            drawingHost.rootView = drawing
            return
        }
        let host = QueryPlanDiagramDrawingHost(rootView: drawing)
        host.sizingOptions = []
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        addSubview(host, positioned: .below, relativeTo: nil)
        drawingHost = host
    }

    private func rebuildNodeElements(for layout: QueryPlanDiagramLayout) {
        nodeElements = layout.nodes.map { positioned in
            let element = QueryPlanDiagramNodeElement()
            element.configure(
                nodeId: positioned.id,
                rect: positioned.rect,
                label: QueryPlanNodeSummary.accessibilityLabel(for: positioned.node),
                canvas: self
            )
            return element
        }
    }

    // MARK: - Pointer

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        pressedNodeId = nodeId(at: convert(event.locationInWindow, from: nil))
    }

    /// A click commits on release over the step it pressed, the contract the SwiftUI tap kept.
    override func mouseUp(with event: NSEvent) {
        guard let pressed = pressedNodeId else { return }
        pressedNodeId = nil
        guard nodeId(at: convert(event.locationInWindow, from: nil)) == pressed else { return }
        selectNode(pressed)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let nodeId = nodeId(at: convert(event.locationInWindow, from: nil)) else { return nil }
        return contextMenu(forNode: nodeId)
    }

    func contextMenu(forNode nodeId: UUID) -> NSMenu? {
        guard let node = planLayout?.nodes.first(where: { $0.id == nodeId })?.node else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(ClosureMenuTarget.item(title: String(localized: "Copy Operation")) {
            ClipboardService.shared.writeText(node.operation)
        })
        menu.addItem(ClosureMenuTarget.item(title: String(localized: "Copy Node Details")) {
            ClipboardService.shared.writeText(QueryPlanNodeSummary.text(for: node))
        })
        return menu
    }

    func showContextMenu(forNode nodeId: UUID) {
        guard let menu = contextMenu(forNode: nodeId),
              let rect = planLayout?.nodes.first(where: { $0.id == nodeId })?.rect else { return }
        menu.popUp(positioning: nil, at: CGPoint(x: rect.minX, y: rect.maxY), in: self)
    }

    // MARK: - Details Popover

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        syncPopover()
    }

    /// Leaving Diagram mode takes the view out of its window. The selection is kept, so coming
    /// back shows the same step's details again.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        guard newWindow == nil else { return }
        dismissPopover()
    }

    private func syncPopover() {
        guard window != nil,
              !visibleRect.isEmpty,
              let selectedNodeId,
              let positioned = planLayout?.nodes.first(where: { $0.id == selectedNodeId }) else {
            dismissPopover()
            return
        }
        guard popoverNodeId != selectedNodeId || popover?.isShown != true else { return }
        dismissPopover()

        let popover = PopoverPresenter.make(behavior: .transient) { _ in
            QueryPlanDetailPane(node: positioned.node)
                .frame(minWidth: 260, maxWidth: 420)
                .padding(4)
        }
        popover.delegate = self
        self.popover = popover
        popoverNodeId = selectedNodeId
        scrollToVisible(positioned.rect)
        popover.show(relativeTo: positioned.rect, of: self, preferredEdge: .maxY)
    }

    /// The delegate goes first, so closing a popover the selection already moved away from does not
    /// clear the selection that replaced it.
    private func dismissPopover() {
        guard let popover else { return }
        self.popover = nil
        popoverNodeId = nil
        popover.delegate = nil
        popover.close()
    }

    // MARK: - Accessibility

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? { .layoutArea }

    override func accessibilityLabel() -> String? {
        QueryPlanViewMode.diagram.title
    }

    override func accessibilityChildren() -> [Any]? {
        nodeElements
    }

    override func accessibilitySelectedChildren() -> [Any]? {
        nodeElements.filter { $0.nodeId == selectedNodeId }
    }

    /// The point arrives in screen coordinates.
    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        guard let window else { return self }
        let local = convert(window.convertPoint(fromScreen: point), from: nil)
        guard let nodeId = nodeId(at: local) else { return self }
        return nodeElements.first { $0.nodeId == nodeId } ?? self
    }
}

extension QueryPlanDiagramCanvasView: NSPopoverDelegate {
    /// A transient popover closes itself on a click outside it, which is how a step is deselected.
    func popoverDidClose(_ notification: Notification) {
        guard let closed = notification.object as? NSPopover, closed === popover else { return }
        popover = nil
        popoverNodeId = nil
        select?(nil)
    }
}

/// Coming back to Diagram mode with a step selected shows its details again, but the canvas arrives
/// in its window before the scroll view has a size or its restored offset, so revealing the step
/// then would scroll a viewport that is about to be replaced.
extension QueryPlanDiagramCanvasView: DiagramViewportSettling {
    func viewportDidSettle() {
        syncPopover()
    }
}

/// One per plan step, published by the canvas rather than mounted as a view. A view that takes no
/// clicks cannot be found by a pointer query from another process: measured, XCUITest reported
/// every step view as not hittable while the ER diagram's elements, built this way, were. So
/// VoiceOver's pointer and Accessibility Inspector reach a step through this element instead.
///
/// Nothing here is `@MainActor`, because AppKit declares these overrides without isolation. Every
/// call still arrives on the main thread, which is what the unchecked conformance and the
/// `assumeIsolated` hops rest on, the same as `ERDiagramNodeElement`. The hops capture only the
/// canvas, which is main-actor isolated, and the step's id, never the element itself.
final class QueryPlanDiagramNodeElement: NSAccessibilityElement, @unchecked Sendable {
    private(set) var nodeId = UUID()
    private var rect: CGRect = .zero
    private weak var canvas: QueryPlanDiagramCanvasView?

    func configure(nodeId: UUID, rect: CGRect, label: String, canvas: QueryPlanDiagramCanvasView) {
        self.nodeId = nodeId
        self.rect = rect
        self.canvas = canvas
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
        setAccessibilityParent(canvas)
    }

    /// Computed on demand from the canvas, so it answers correctly at every magnification and
    /// scroll offset with nothing to invalidate.
    override func accessibilityFrame() -> NSRect {
        guard let canvas else { return .zero }
        return NSAccessibility.screenRect(fromView: canvas, rect: rect)
    }

    override func accessibilityPerformPress() -> Bool {
        guard let canvas else { return false }
        let nodeId = nodeId
        return MainActor.assumeIsolated {
            canvas.selectNode(nodeId)
            return true
        }
    }

    override func accessibilityPerformShowMenu() -> Bool {
        guard let canvas else { return false }
        let nodeId = nodeId
        return MainActor.assumeIsolated {
            canvas.showContextMenu(forNode: nodeId)
            return true
        }
    }
}

/// Draws and nothing else: clicks go to the canvas under it, and its SwiftUI tree publishes nothing
/// to accessibility, where the canvas's own step elements stand in for it.
final class QueryPlanDiagramDrawingHost: NSHostingView<QueryPlanDiagramDrawing> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func isAccessibilityElement() -> Bool { false }

    override func accessibilityChildren() -> [Any]? { [] }
}
