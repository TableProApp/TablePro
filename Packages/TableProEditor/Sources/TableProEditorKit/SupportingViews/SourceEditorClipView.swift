//
//  SourceEditorClipView.swift
//  TableProEditorKit
//

import AppKit
import TableProTextEngine

/// The editor's clip view, which adds the room the floating views take to the insets AppKit works out for it.
///
/// AppKit keeps adjusting the clip view's insets itself, for the scroll view's own insets, the title bar, and the room a
/// ruler, a header or a legacy scroller takes, and it reads them back through ``contentInsets`` whenever it reveals a
/// range, clamps the scroll position, autoscrolls during a drag or sizes a scroller. Adding the reservation in the getter
/// leaves that adjustment on for good. Turning it off and on again around a tile drops the reservation for the length of
/// the tile, and AppKit clamps the scroll position to the narrower edge each time.
final class SourceEditorClipView: NSClipView {
    /// The widths of the views floating along the leading and trailing edges.
    var floatingSubviewInsets: HorizontalEdgeInsets = .zero

    override var contentInsets: NSEdgeInsets {
        get {
            let computed = super.contentInsets
            return NSEdgeInsets(
                top: computed.top,
                left: computed.left + floatingSubviewInsets.left,
                bottom: computed.bottom,
                right: computed.right + floatingSubviewInsets.right
            )
        }
        set {
            super.contentInsets = newValue
        }
    }
}
