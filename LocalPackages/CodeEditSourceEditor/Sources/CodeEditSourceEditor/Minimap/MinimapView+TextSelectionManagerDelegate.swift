//
//  MinimapView+TextSelectionManagerDelegate.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 4/16/25.
//

import AppKit
import CodeEditTextView

extension MinimapView: TextSelectionManagerDelegate {
    public var visibleTextRange: NSRange? {
        let minY = max(visibleRect.minY, 0)
        let maxY = min(visibleRect.maxY, layoutManager?.estimatedHeight() ?? 3.0)
        guard let minYLine = layoutManager?.textLineForPosition(minY),
              let maxYLine = layoutManager?.textLineForPosition(maxY) else {
            return nil
        }
        return NSRange(start: minYLine.range.location, end: maxYLine.range.max)
    }

    public func setNeedsDisplay() {
        contentView.needsDisplay = true
    }

    public func estimatedLineHeight() -> CGFloat {
        layoutManager?.estimateLineHeight() ?? 3.0
    }
}
