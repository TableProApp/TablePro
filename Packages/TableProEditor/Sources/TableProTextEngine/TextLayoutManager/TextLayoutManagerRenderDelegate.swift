//
//  TextLayoutManagerRenderDelegate.swift
//  TableProTextEngine
//
//  Created by Khan Winter on 4/10/25.
//

import AppKit

/// Provide an instance of this class to the ``TextLayoutManager`` to override how the layout manager performs layout
/// and display for text lines and fragments.
///
/// All methods on this protocol are optional, and default to the default behavior.
public protocol TextLayoutManagerRenderDelegate: AnyObject {
    func prepareForDisplay(
        textLine: TextLine,
        displayData: TextLine.DisplayData,
        range: NSRange,
        stringRef: NSTextStorage,
        markedRanges: MarkedRanges?,
        attachments: [AnyTextAttachment]
    )

    func estimatedLineHeight() -> CGFloat?

    func lineFragmentView(for lineFragment: LineFragment) -> LineFragmentView

    func characterXPosition(in lineFragment: LineFragment, for offset: Int) -> CGFloat
}

public extension TextLayoutManagerRenderDelegate {
    func prepareForDisplay(
        textLine: TextLine,
        displayData: TextLine.DisplayData,
        range: NSRange,
        stringRef: NSTextStorage,
        markedRanges: MarkedRanges?,
        attachments: [AnyTextAttachment]
    ) {
        textLine.prepareForDisplay(
            displayData: displayData,
            range: range,
            stringRef: stringRef,
            markedRanges: markedRanges,
            attachments: attachments
        )
    }

    func estimatedLineHeight() -> CGFloat? {
        nil
    }

    func lineFragmentView(for lineFragment: LineFragment) -> LineFragmentView {
        LineFragmentView()
    }

    func characterXPosition(in lineFragment: LineFragment, for offset: Int) -> CGFloat {
        lineFragment.xPosition(for: offset)
    }
}
