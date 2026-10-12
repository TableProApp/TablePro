//
//  TreeOutlineAccessoryViews.swift
//  TablePro
//

import AppKit

/// `NSColor.drawSwatch(in:)` is what color wells draw with: a flat fill for an opaque color, and a
/// color with alpha split on the diagonal over black and over white.
internal final class TreeColorSwatchView: NSView {
    internal static let side: CGFloat = 12
    private static let cornerRadius: CGFloat = 3

    internal var color: NSColor = .clear {
        didSet {
            guard color != oldValue else { return }
            needsDisplay = true
        }
    }

    internal var isOnEmphasizedRow = false {
        didSet {
            guard isOnEmphasizedRow != oldValue else { return }
            needsDisplay = true
        }
    }

    override internal init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(String(localized: "Color preview"))
    }

    @available(*, unavailable)
    internal required init?(coder: NSCoder) {
        fatalError("TreeColorSwatchView does not support NSCoder init")
    }

    override internal var intrinsicContentSize: NSSize {
        NSSize(width: Self.side, height: Self.side)
    }

    /// A right-click here belongs to the row's menu, which in the inspector is a SwiftUI menu
    /// the swatch would otherwise swallow.
    override internal func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override internal func draw(_ dirtyRect: NSRect) {
        let outline = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: Self.cornerRadius,
            yRadius: Self.cornerRadius
        )
        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        color.drawSwatch(in: bounds)
        NSGraphicsContext.restoreGraphicsState()

        /// The stroke is what keeps a white swatch visible on a light row and a near-black one on
        /// a dark row.
        let stroke = isOnEmphasizedRow
            ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.6)
            : NSColor.tertiaryLabelColor
        stroke.setStroke()
        outline.lineWidth = 1
        outline.stroke()
    }
}

internal final class TreeBadgeView: NSView {
    private static let horizontalPadding: CGFloat = 6
    private static let verticalPadding: CGFloat = 1

    private static var font: NSFont {
        .systemFont(ofSize: NSFont.preferredFont(forTextStyle: .caption2).pointSize, weight: .medium)
    }

    internal var text = "" {
        didSet {
            guard text != oldValue else { return }
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    internal var isOnEmphasizedRow = false {
        didSet {
            guard isOnEmphasizedRow != oldValue else { return }
            needsDisplay = true
        }
    }

    override internal var intrinsicContentSize: NSSize {
        let size = (text as NSString).size(withAttributes: [.font: Self.font])
        return NSSize(
            width: ceil(size.width) + 2 * Self.horizontalPadding,
            height: ceil(size.height) + 2 * Self.verticalPadding
        )
    }

    override internal func draw(_ dirtyRect: NSRect) {
        let selectedText = NSColor.alternateSelectedControlTextColor
        let fill = isOnEmphasizedRow ? selectedText.withAlphaComponent(0.2) : NSColor.quaternaryLabelColor
        fill.setFill()
        let radius = bounds.height / 2
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.font,
            .foregroundColor: isOnEmphasizedRow ? selectedText.withAlphaComponent(0.8) : NSColor.tertiaryLabelColor
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let origin = NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2)
        (text as NSString).draw(at: origin, withAttributes: attributes)
    }
}
