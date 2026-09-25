//
//  MagnifiableCanvasView.swift
//  TablePro
//
//  A diagram viewport backed by NSScrollView's own magnification. Pinch anchored at the
//  pointer, two-finger double tap to smart magnify, real scrollers that follow the system
//  setting and elastic scrolling all come from AppKit rather than being rebuilt on top of a
//  SwiftUI ScrollView. Cmd+scroll does not come from AppKit; `DiagramScrollView` adds it.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class DiagramViewportController: ObservableObject {
    @Published private(set) var magnification: CGFloat = 1.0

    private enum Placement {
        case fit
        case offset(CGPoint)
    }

    private weak var scrollView: DiagramScrollView?
    private var magnificationObservation: NSKeyValueObservation?
    private var pendingPlacement: Placement?

    var visibleDocumentRect: CGRect {
        scrollView?.documentVisibleRect ?? .zero
    }

    var canZoomIn: Bool { DiagramZoom.canStepUp(from: magnification) }
    var canZoomOut: Bool { DiagramZoom.canStepDown(from: magnification) }

    func zoomIn() {
        guard canZoomIn else { return }
        apply(DiagramZoom.stepUp(from: magnification))
    }

    func zoomOut() {
        guard canZoomOut else { return }
        apply(DiagramZoom.stepDown(from: magnification))
    }

    func resetZoom() {
        apply(1.0)
    }

    /// Fits the whole diagram, but never zooms past 100%: a two-node plan blown up to fill the
    /// window reads worse than the same plan at its natural size.
    func fitToWindow() {
        fitWholeDocument()
    }

    func fitToWindowOnceLaidOut() {
        pendingPlacement = .fit
        placeDocumentIfLaidOut()
    }

    /// Clamped through the clip view's own rule, so a fast pan or a node dragged against the edge
    /// cannot push the document out of view and have AppKit snap it back on the next tile. Returns
    /// the distance actually scrolled, which is less than asked for, or nothing, at an edge.
    @discardableResult
    func scrollBy(_ delta: CGSize) -> CGSize {
        guard let scrollView else { return .zero }
        let clipView = scrollView.contentView
        let start = clipView.bounds.origin
        let proposed = CGRect(
            origin: CGPoint(x: start.x + delta.width, y: start.y + delta.height),
            size: clipView.bounds.size
        )
        clipView.scroll(to: clipView.constrainBoundsRect(proposed).origin)
        scrollView.reflectScrolledClipView(clipView)
        let end = clipView.bounds.origin
        return CGSize(width: end.x - start.x, height: end.y - start.y)
    }

    /// Auto-pan grows the canvas a step at a time and cannot wait for SwiftUI to hand the document its
    /// new size, or every step stalls until the next update. The size written is the one SwiftUI is
    /// about to write, so its update then finds nothing to change.
    func resizeDocument(to size: CGSize) {
        guard let documentView = scrollView?.documentView, documentView.frame.size != size else { return }
        documentView.setFrameSize(size)
    }

    /// Pushes the retained zoom onto the new scroll view rather than reading the scroll view's
    /// own 1.0, because a controller outlives the view it is attached to: an editor-tab switch
    /// tears the diagram down and rebuilds it, and reading would drop the user back to 100%.
    func attach(to scrollView: DiagramScrollView) {
        if let attached = self.scrollView, attached !== scrollView {
            detach(from: attached)
        }
        self.scrollView = scrollView
        scrollView.zoomController = self
        scrollView.magnification = DiagramZoom.clamped(magnification)
        magnification = scrollView.magnification
        magnificationObservation = scrollView.observe(\.magnification, options: [.new]) { [weak self] _, change in
            guard let value = change.newValue else { return }
            MainActor.assumeIsolated {
                self?.magnification = value
            }
        }
        placeDocumentIfLaidOut()
    }

    /// An offset applied while the clip view has no size is rescaled by AppKit when the frame arrives,
    /// measured at 1.5x as the saved origin divided by the zoom, and a fit against no size has
    /// nothing to fit to. So either waits for a size: at once when the scroll view already has one,
    /// otherwise on the scroll view's first tile that gives it one.
    func placeDocumentIfLaidOut() {
        guard let scrollView, let placement = pendingPlacement, !scrollView.contentView.bounds.isEmpty else { return }
        switch placement {
        case .fit:
            guard fitWholeDocument() else { return }
        case .offset(let origin):
            restoreOffset(origin, in: scrollView)
        }
        pendingPlacement = nil
    }

    /// SwiftUI makes a replacement canvas before it dismantles the one it replaces, so the controller
    /// can already belong to the new scroll view when the old one is torn down. A scroll view that
    /// never had a size has no offset worth keeping over the placement still waiting to be applied.
    func detach(from scrollView: DiagramScrollView) {
        guard self.scrollView === scrollView else { return }
        if !scrollView.contentView.bounds.isEmpty {
            pendingPlacement = .offset(scrollView.contentView.bounds.origin)
        }
        magnificationObservation?.invalidate()
        magnificationObservation = nil
        scrollView.zoomController = nil
        self.scrollView = nil
    }

    @discardableResult
    private func fitWholeDocument() -> Bool {
        guard let scrollView, let documentView = scrollView.documentView else { return false }
        let content = documentView.bounds.size
        let visible = scrollView.contentSize
        guard content.width > 0, content.height > 0, visible.width > 0, visible.height > 0 else { return false }

        apply(min(1.0, min(visible.width / content.width, visible.height / content.height)))
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        return true
    }

    private func restoreOffset(_ origin: CGPoint, in scrollView: DiagramScrollView) {
        let clipView = scrollView.contentView
        let proposed = CGRect(origin: origin, size: clipView.bounds.size)
        clipView.scroll(to: clipView.constrainBoundsRect(proposed).origin)
        scrollView.reflectScrolledClipView(clipView)
    }

    private func apply(_ value: CGFloat) {
        let clamped = DiagramZoom.clamped(value)
        guard let scrollView else {
            magnification = clamped
            return
        }

        let centre = CGPoint(x: visibleDocumentRect.midX, y: visibleDocumentRect.midY)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = MotionAccessibility.systemReduceMotion ? 0 : 0.2
            context.allowsImplicitAnimation = true
            scrollView.setMagnification(clamped, centeredAt: centre)
        }
        magnification = scrollView.magnification
    }
}

/// The document is an AppKit view, never SwiftUI. SwiftUI inside a magnified scroll view resolves
/// clicks, hover and drags in unscaled space, measured on macOS 27: at 50% a click on document point
/// (950, 650) reached SwiftUI as (475, 325). `NSView.convert(_:from:)` accounts for the clip view's
/// scale, so a document view that owns its own pointer events hits what is under the pointer.
struct MagnifiableCanvasView<Document: NSView>: NSViewRepresentable {
    let viewport: DiagramViewportController
    let contentSize: CGSize
    var accessibilityIdentifier: String?
    let makeDocument: () -> Document
    let updateDocument: (Document) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> DiagramScrollView {
        let scrollView = DiagramScrollView()
        scrollView.allowsMagnification = true
        scrollView.minMagnification = DiagramZoom.minimum
        scrollView.maxMagnification = DiagramZoom.maximum
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        if let accessibilityIdentifier {
            scrollView.setAccessibilityIdentifier(accessibilityIdentifier)
        }

        let document = makeDocument()
        document.frame = CGRect(origin: .zero, size: resolvedContentSize)
        updateDocument(document)
        scrollView.documentView = document

        context.coordinator.document = document
        context.coordinator.viewport = viewport
        viewport.attach(to: scrollView)
        return scrollView
    }

    func updateNSView(_ scrollView: DiagramScrollView, context: Context) {
        guard let document = context.coordinator.document else { return }
        if context.coordinator.viewport !== viewport {
            context.coordinator.viewport?.detach(from: scrollView)
            context.coordinator.viewport = viewport
            viewport.attach(to: scrollView)
        }
        updateDocument(document)

        let size = resolvedContentSize
        guard document.frame.size != size else { return }
        document.frame = CGRect(origin: .zero, size: size)
    }

    static func dismantleNSView(_ scrollView: DiagramScrollView, coordinator: Coordinator) {
        MainActor.assumeIsolated {
            coordinator.viewport?.detach(from: scrollView)
            coordinator.viewport = nil
            coordinator.document = nil
        }
    }

    /// Returning the proposal keeps the document's size out of SwiftUI's layout, so a wide
    /// diagram never becomes a minimum width that pins the window's split dividers.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DiagramScrollView, context: Context) -> CGSize? {
        let resolved = proposal.replacingUnspecifiedDimensions(by: CGSize(width: 400, height: 300))
        guard resolved.width.isFinite, resolved.height.isFinite else { return nil }
        return resolved
    }

    private var resolvedContentSize: CGSize {
        CGSize(
            width: max(1, contentSize.width.isFinite ? contentSize.width : 1),
            height: max(1, contentSize.height.isFinite ? contentSize.height : 1)
        )
    }

    @MainActor
    final class Coordinator {
        var document: Document?
        var viewport: DiagramViewportController?
    }
}
