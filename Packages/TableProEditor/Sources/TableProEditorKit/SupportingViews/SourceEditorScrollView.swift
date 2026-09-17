//
//  SourceEditorScrollView.swift
//  TableProEditorKit
//

import AppKit
import TableProTextEngine

/// The editor's scroll view, which keeps the text clear of the views floating along its leading and trailing edges.
///
/// The gutter and the minimap are floating subviews. They sit over the clip view rather than beside it, so on its own
/// AppKit treats the whole clip view as showing the document. Their widths are reserved on the clip view's content
/// insets, the channel AppKit itself uses to make room for a ruler or a table header. Revealing a range, clamping the
/// scroll position, autoscrolling during a drag and re-clamping after the document narrows then all stop at the edge
/// of the chrome, instead of carrying the start of each line underneath the gutter.
///
/// ``SourceEditorClipView`` adds the reservation on top of the insets AppKit works out, so laying the scroll view out
/// never moves the clip view. AppKit tiles at the start of every scroll gesture, and a tile that put the clip view
/// back where it thought it belonged snapped a scroll that had just left the leading edge, and the bounce past that
/// edge, straight back to it.
public final class SourceEditorScrollView: NSScrollView {
    /// Where the clip view sits horizontally before the reservation changes, so it can be put back afterwards.
    private enum HorizontalPlacement {
        case leadingEdge
        case trailingEdge
        case offset(CGFloat)
    }

    /// AppKit aligns the clip view's origin to the backing store's pixels, and a gutter's width is fractional, so an
    /// edge is only ever reached to within a fraction of a point.
    private static let edgeTolerance: CGFloat = 0.5

    private let reservingClipView = SourceEditorClipView()

    override public init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        contentView = reservingClipView
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        contentView = reservingClipView
    }

    /// The widths of the views floating along the leading and trailing edges.
    ///
    /// A view resting at an edge stays at that edge when they change, so a gutter that gains a digit moves the text over
    /// rather than covering the start of every line, and a minimap appearing does not cover the end of the widest line.
    /// A view scrolled anywhere else keeps its offset.
    public internal(set) var floatingSubviewInsets: HorizontalEdgeInsets {
        get {
            reservingClipView.floatingSubviewInsets
        }
        set {
            guard newValue != reservingClipView.floatingSubviewInsets else { return }
            let placement = horizontalPlacement()
            reservingClipView.floatingSubviewInsets = newValue
            restore(placement)
        }
    }

    private func horizontalPlacement() -> HorizontalPlacement {
        let bounds = contentView.bounds
        if bounds.minX <= -contentView.contentInsets.left + Self.edgeTolerance {
            return .leadingEdge
        }
        let furthest = NSRect(origin: NSPoint(x: documentView?.frame.maxX ?? bounds.minX, y: bounds.minY), size: bounds.size)
        let trailingEdge = contentView.constrainBoundsRect(furthest).minX
        return bounds.minX >= trailingEdge - Self.edgeTolerance ? .trailingEdge : .offset(bounds.minX)
    }

    private func restore(_ placement: HorizontalPlacement) {
        guard let documentView else { return }
        let targetX = switch placement {
        case .leadingEdge:
            -contentView.contentInsets.left
        case .trailingEdge:
            documentView.frame.maxX
        case .offset(let offset):
            offset
        }
        documentView.scroll(NSPoint(x: targetX, y: contentView.bounds.minY))
        reflectScrolledClipView(contentView)
    }
}
