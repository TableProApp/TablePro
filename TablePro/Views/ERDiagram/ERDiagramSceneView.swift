//
//  ERDiagramSceneView.swift
//  TablePro
//
//  The diagram's drawing surface, as an AppKit view rather than a SwiftUI `Canvas`.
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
//  rect. The view takes no clicks (`hitTest` returns nil), so every gesture, hover and
//  accessibility modifier `ERDiagramView` puts on it keeps working exactly as before.
//

import AppKit
import SwiftUI

final class ERDiagramSceneView: NSView {
    var scene = ERDiagramScene() {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        ERDiagramSceneRenderer.draw(scene, dirtyRect: dirtyRect, in: context)
    }
}

struct ERDiagramSceneCanvas: NSViewRepresentable {
    let scene: ERDiagramScene

    func makeNSView(context: Context) -> ERDiagramSceneView {
        let view = ERDiagramSceneView()
        view.setAccessibilityElement(false)
        view.scene = scene
        return view
    }

    func updateNSView(_ nsView: ERDiagramSceneView, context: Context) {
        nsView.scene = scene
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ERDiagramSceneView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: scene.size)
    }
}
