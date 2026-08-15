//
//  MagnifiableCanvasView.swift
//  TablePro
//
//  A diagram viewport backed by NSScrollView's own magnification. Pinch anchored at the
//  pointer, two-finger double tap to smart magnify, Cmd+scroll to zoom, real scrollers that
//  follow the system setting and elastic scrolling all come from AppKit rather than being
//  rebuilt on top of a SwiftUI ScrollView.
//

import AppKit
import SwiftUI

@MainActor
@Observable
final class DiagramViewportController {
    private(set) var magnification: CGFloat = 1.0

    @ObservationIgnored private weak var scrollView: NSScrollView?
    @ObservationIgnored private var magnificationObservation: NSKeyValueObservation?

    var visibleDocumentRect: CGRect {
        scrollView?.documentVisibleRect ?? .zero
    }

    func zoomIn() {
        apply(magnification + DiagramZoom.step)
    }

    func zoomOut() {
        apply(magnification - DiagramZoom.step)
    }

    func resetZoom() {
        apply(1.0)
    }

    /// Fits the whole diagram, but never zooms past 100%: a two-node plan blown up to fill the
    /// window reads worse than the same plan at its natural size.
    func fitToWindow() {
        guard let scrollView, let documentView = scrollView.documentView else { return }
        let content = documentView.bounds.size
        let visible = scrollView.contentSize
        guard content.width > 0, content.height > 0, visible.width > 0, visible.height > 0 else { return }

        apply(min(1.0, min(visible.width / content.width, visible.height / content.height)))
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Clamped through the clip view's own rule, so a fast pan or a node dragged against the edge
    /// cannot push the document out of view and have AppKit snap it back on the next tile.
    func scrollBy(_ delta: CGSize) {
        guard let scrollView else { return }
        let clipView = scrollView.contentView
        let proposed = CGRect(
            origin: CGPoint(
                x: clipView.bounds.origin.x + delta.width,
                y: clipView.bounds.origin.y + delta.height
            ),
            size: clipView.bounds.size
        )
        clipView.scroll(to: clipView.constrainBoundsRect(proposed).origin)
        scrollView.reflectScrolledClipView(clipView)
    }

    func attach(to scrollView: NSScrollView) {
        self.scrollView = scrollView
        magnification = scrollView.magnification
        magnificationObservation = scrollView.observe(\.magnification, options: [.new]) { [weak self] _, change in
            guard let value = change.newValue else { return }
            MainActor.assumeIsolated {
                self?.magnification = value
            }
        }
    }

    func detach() {
        magnificationObservation?.invalidate()
        magnificationObservation = nil
        scrollView = nil
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

struct MagnifiableCanvasView<Content: View>: NSViewRepresentable {
    let viewport: DiagramViewportController
    let contentSize: CGSize
    var accessibilityIdentifier: String?
    @ViewBuilder let content: () -> Content

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
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

        let hostingView = NSHostingView(rootView: content())
        hostingView.translatesAutoresizingMaskIntoConstraints = true
        hostingView.frame = CGRect(origin: .zero, size: resolvedContentSize)
        scrollView.documentView = hostingView

        context.coordinator.hostingView = hostingView
        context.coordinator.viewport = viewport
        viewport.attach(to: scrollView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let hostingView = context.coordinator.hostingView else { return }
        hostingView.rootView = content()

        let size = resolvedContentSize
        guard hostingView.frame.size != size else { return }
        hostingView.frame = CGRect(origin: .zero, size: size)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        MainActor.assumeIsolated {
            coordinator.viewport?.detach()
            coordinator.viewport = nil
            coordinator.hostingView = nil
        }
    }

    /// Returning the proposal keeps the document's size out of SwiftUI's layout, so a wide
    /// diagram never becomes a minimum width that pins the window's split dividers.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
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
        var hostingView: NSHostingView<Content>?
        var viewport: DiagramViewportController?
    }
}
