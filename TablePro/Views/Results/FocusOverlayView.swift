//
//  FocusOverlayView.swift
//  TablePro
//

import AppKit

@MainActor
final class FocusOverlayView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func makeBackingLayer() -> CALayer {
        let layer = super.makeBackingLayer()
        layer.actions = Self.disabledLayerActions
        layer.zPosition = 1000
        return layer
    }

    private static let disabledLayerActions: [String: any CAAction] = [
        "position": NSNull(),
        "bounds": NSNull(),
        "frame": NSNull(),
        "contents": NSNull(),
        "hidden": NSNull(),
    ]

    override func draw(_ dirtyRect: NSRect) {
        guard !isHidden else { return }
        let path = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        path.lineWidth = 2
        NSColor.alternateSelectedControlTextColor.setStroke()
        path.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if !isHidden { needsDisplay = true }
    }

    func reposition(at frame: NSRect) {
        if frame.isEmpty {
            if !isHidden { isHidden = true }
            return
        }
        if self.frame != frame {
            self.frame = frame
            needsDisplay = true
        }
        if isHidden {
            isHidden = false
            needsDisplay = true
        }
    }

    func dismiss() {
        guard !isHidden else { return }
        isHidden = true
    }
}
