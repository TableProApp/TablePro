//
//  CursorView.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 8/15/23.
//

import AppKit

/// Animates a cursor. Will sync animation with any other cursor views.
open class CursorView: NSView {
    /// The color of the cursor.
    public var color: NSColor {
        didSet {
            layer?.backgroundColor = color.cgColor
        }
    }

    /// The width of the cursor.
    private let width: CGFloat
    /// The timer observer.
    private var observer: NSObjectProtocol?

    open override var isFlipped: Bool {
        true
    }

    override open func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Create a cursor view.
    /// - Parameters:
    ///   - blinkDuration: The duration to blink, leave as nil to never blink.
    ///   - color: The color of the cursor.
    ///   - width: How wide the cursor should be.
    init(
        color: NSColor = NSColor.labelColor,
        width: CGFloat = 1.0
    ) {
        self.color = color
        self.width = width

        super.init(frame: .zero)

        frame.size.width = width
        wantsLayer = true
        layer?.backgroundColor = color.cgColor
    }

    func blinkTimer(_ shouldHideCursor: Bool) {
        self.isHidden = shouldHideCursor
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
