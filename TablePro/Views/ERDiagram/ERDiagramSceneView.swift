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
        didSet {
            needsDisplay = true
            accessibilityTree.invalidate()
            announceSelectionChange(from: oldValue.selectedNodeId)
        }
    }

    private let accessibilityTree = ERDiagramAccessibilityTree()

    override var isFlipped: Bool { true }

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        ERDiagramSceneRenderer.draw(scene, dirtyRect: dirtyRect, in: context)
    }

    // MARK: - Accessibility

    /// The diagram is a canvas of tables rather than one picture, so it is published as a layout
    /// area with an element per table. Nothing is mounted for it: a plain `NSView` publishes
    /// `NSAccessibilityElement` children directly, which is the part of the data grid's rule that
    /// does not generalise (`NSTableView` builds its cell tree from cell views alone, and this is
    /// not a table view). Measured on macOS 27: those children reach an assistive client through
    /// the enclosing `NSHostingView`, and a pointer query descends into them.
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

struct ERDiagramSceneCanvas: NSViewRepresentable {
    let scene: ERDiagramScene

    func makeNSView(context: Context) -> ERDiagramSceneView {
        let view = ERDiagramSceneView()
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
