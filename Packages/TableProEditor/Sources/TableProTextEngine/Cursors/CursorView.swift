//
//  CursorView.swift
//  TableProTextEngine
//
//  Created by Khan Winter on 8/15/23.
//

import AppKit

/// Animates a cursor. Will sync animation with any other cursor views.
open class CursorView: NSView {
    public var color: NSColor {
        didSet {
            needsDisplay = true
        }
    }

    /// The width of the cursor.
    private let width: CGFloat
    /// The timer observer.
    private var observer: NSObjectProtocol?

    override open var isFlipped: Bool {
        true
    }

    /// The layer holds a resolved color, so it is set where AppKit has made this view's appearance current, and set
    /// again whenever that appearance changes.
    override open var wantsUpdateLayer: Bool {
        true
    }

    override open func hitTest(_ point: NSPoint) -> NSView? { nil }

    init(
        color: NSColor = NSColor.labelColor,
        width: CGFloat = 1.0
    ) {
        self.color = color
        self.width = width

        super.init(frame: .zero)

        frame.size.width = width
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        needsDisplay = true
    }

    override open func updateLayer() {
        layer?.backgroundColor = color.safeCGColor
    }

    func blinkTimer(_ shouldHideCursor: Bool) {
        self.isHidden = shouldHideCursor
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
