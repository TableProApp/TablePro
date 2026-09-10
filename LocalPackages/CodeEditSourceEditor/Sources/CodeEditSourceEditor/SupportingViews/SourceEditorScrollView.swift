//
//  SourceEditorScrollView.swift
//  CodeEditSourceEditor
//

import AppKit
import CodeEditTextView

/// The editor's scroll view, which keeps the text clear of the views floating along its leading and trailing edges.
///
/// The gutter and the minimap are floating subviews. They sit over the clip view rather than beside it, so on its own
/// AppKit treats the whole clip view as showing the document. Their widths are reserved on the clip view's content
/// insets, the channel AppKit itself uses to make room for a ruler or a table header. Revealing a range, clamping the
/// scroll position, autoscrolling during a drag and re-clamping after the document narrows then all stop at the edge
/// of the chrome, instead of carrying the start of each line underneath the gutter.
///
/// The reservation is added in ``tile()``, on top of the insets AppKit works out for the clip view on that same tile:
/// the scroll view's own ``contentInsets`` and title bar, and the room a ruler, a header or a legacy scroller takes.
/// The clip view computes those only while it adjusts its insets automatically, so it does so for the length of
/// `super.tile()` and stops before the reservation is written, or the next tile would drop it.
public final class SourceEditorScrollView: NSScrollView {
    /// Where the clip view sits horizontally before a tile, so it can be put back afterwards.
    private enum HorizontalPlacement {
        case leadingEdge
        case trailingEdge
        case offset(CGFloat)
    }

    /// AppKit aligns the clip view's origin to the backing store's pixels, and a gutter's width is fractional, so an
    /// edge is only ever reached to within a fraction of a point.
    private static let edgeTolerance: CGFloat = 0.5

    /// The widths of the views floating along the leading and trailing edges.
    public internal(set) var floatingSubviewInsets: HorizontalEdgeInsets = .zero {
        didSet {
            guard floatingSubviewInsets != oldValue else { return }
            tile()
        }
    }

    override public func tile() {
        let placement = horizontalPlacement()

        contentView.automaticallyAdjustsContentInsets = true
        super.tile()
        let computed = contentView.contentInsets
        contentView.automaticallyAdjustsContentInsets = false
        contentView.contentInsets = NSEdgeInsets(
            top: computed.top,
            left: computed.left + floatingSubviewInsets.left,
            bottom: computed.bottom,
            right: computed.right + floatingSubviewInsets.right
        )

        restore(placement)
    }

    /// A clip view that shows the start of the document, even partly under the leading reservation, is at the leading
    /// edge and stays there, so a gutter that gains a digit moves the text over rather than covering the start of
    /// every line. One showing the end of the widest line stays at the trailing edge, so a minimap appearing does not
    /// cover it. Anywhere else keeps its offset.
    private func horizontalPlacement() -> HorizontalPlacement {
        let bounds = contentView.bounds
        if bounds.minX <= Self.edgeTolerance {
            return .leadingEdge
        }
        let furthest = NSRect(origin: NSPoint(x: documentView?.frame.maxX ?? bounds.minX, y: bounds.minY), size: bounds.size)
        let trailingEdge = contentView.constrainBoundsRect(furthest).minX
        return bounds.minX >= trailingEdge - Self.edgeTolerance ? .trailingEdge : .offset(bounds.minX)
    }

    private func restore(_ placement: HorizontalPlacement) {
        guard let documentView else { return }
        let x = switch placement {
        case .leadingEdge:
            -contentView.contentInsets.left
        case .trailingEdge:
            documentView.frame.maxX
        case .offset(let offset):
            offset
        }
        documentView.scroll(NSPoint(x: x, y: contentView.bounds.minY))
        reflectScrolledClipView(contentView)
    }
}
