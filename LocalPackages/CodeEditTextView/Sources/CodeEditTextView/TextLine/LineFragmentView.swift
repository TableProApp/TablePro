//
//  LineFragmentView.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 8/14/23.
//

import AppKit

/// Displays a line fragment.
open class LineFragmentView: NSView {
    public weak var lineFragment: LineFragment?
    public weak var renderer: LineFragmentRenderer?
#if DEBUG_LINE_INVALIDATION
    private var backgroundAnimation: CABasicAnimation?
#endif

    open override var isFlipped: Bool {
        true
    }

    open override var isOpaque: Bool {
        false
    }

    open override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required public init?(coder: NSCoder) {
        super.init(coder: coder)
    }

#if DEBUG_LINE_INVALIDATION
    /// Setup background animation from random color to clear when this fragment is invalidated.
    private func setupBackgroundAnimation() {
        self.wantsLayer = true

        let randomColor = NSColor(
            red: CGFloat.random(in: 0...1),
            green: CGFloat.random(in: 0...1),
            blue: CGFloat.random(in: 0...1),
            alpha: 0.3
        )

        self.layer?.backgroundColor = randomColor.cgColor

        let animation = CABasicAnimation(keyPath: "backgroundColor")
        animation.fromValue = randomColor.cgColor
        animation.toValue = NSColor.clear.cgColor
        animation.duration = 1.0
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        self.layer?.add(animation, forKey: "backgroundColorAnimation")

        DispatchQueue.main.asyncAfter(deadline: .now() + animation.duration) {
            self.layer?.backgroundColor = NSColor.clear.cgColor
        }
    }
#endif

    open override func prepareForReuse() {
        super.prepareForReuse()
        lineFragment = nil

#if DEBUG_LINE_INVALIDATION
        setupBackgroundAnimation()
#endif
    }

    /// Set a new line fragment for this view, updating view size.
    /// - Parameter newFragment: The new fragment to use.
    open func setLineFragment(_ newFragment: LineFragment, fragmentRange: NSRange, renderer: LineFragmentRenderer) {
        self.lineFragment = newFragment
        self.renderer = renderer
        self.frame.size = CGSize(width: newFragment.width, height: newFragment.scaledHeight)
    }

    /// Draws the line fragment in the graphics context.
    open override func draw(_ dirtyRect: NSRect) {
        guard let lineFragment, let context = NSGraphicsContext.current?.cgContext else {
            return
        }

        renderer?.draw(lineFragment: lineFragment, in: context, yPos: 0.0)
    }
}
