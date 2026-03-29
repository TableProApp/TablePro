//
//  TextView+TextSelectionManagerDelegate.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 6/15/24.
//

import Foundation

extension TextView: TextSelectionManagerDelegate {
    public func setNeedsDisplay() {
        self.setNeedsDisplay(frame)
    }

    public func estimatedLineHeight() -> CGFloat {
        layoutManager.estimateLineHeight()
    }
}
