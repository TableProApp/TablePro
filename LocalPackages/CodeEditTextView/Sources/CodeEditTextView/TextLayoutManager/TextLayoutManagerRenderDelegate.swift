//
//  TextLayoutManagerRenderDelegate.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 4/10/25.
//

import AppKit

/// Provide an instance of this class to the ``TextLayoutManager`` to override how the layout manager performs layout
/// and display for text lines and fragments.
///
/// All methods on this protocol are optional, and default to the default behavior.
public protocol TextLayoutManagerRenderDelegate: AnyObject {
    func prepareForDisplay( // swiftlint:disable:this function_parameter_count
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
    func prepareForDisplay( // swiftlint:disable:this function_parameter_count
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
        lineFragment._xPos(for: offset)
    }
}
