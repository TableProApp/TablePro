//
//  LineFragmentView.swift
//  TableProTextEngine
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

    override open var isFlipped: Bool {
        true
    }

    override open var isOpaque: Bool {
        false
    }

    override open func hitTest(_ point: NSPoint) -> NSView? { nil }

    override public init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        /// `NSView.clipsToBounds` defaults to YES before macOS 14 and NO from 14 on (NSView.h), and
        /// the whole renderer is written against the later default: a fragment's ink reaches past
        /// its own width, and `LineFragmentRenderer` reads the context's clip to decide how much of
        /// a line to draw. Left at the earlier default, a fragment is clipped to itself and a
        /// fragment whose frame is briefly wrong draws nothing at all rather than overflowing.
        /// `API_AVAILABLE(macos(10.9))` on the property means no availability check can see this.
        clipsToBounds = false
    }

    public required init?(coder: NSCoder) {
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

    override open func prepareForReuse() {
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
    override open func draw(_ dirtyRect: NSRect) {
        guard let lineFragment, let context = NSGraphicsContext.current?.cgContext else {
            return
        }

        renderer?.draw(lineFragment: lineFragment, in: context, yPos: 0.0)
    }
}
