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
        layoutManager?.textRange(covering: visibleRect)
    }

    public func setNeedsDisplay() {
        contentView.needsDisplay = true
    }

    public func estimatedLineHeight() -> CGFloat {
        layoutManager?.estimateLineHeight() ?? 3.0
    }
}
