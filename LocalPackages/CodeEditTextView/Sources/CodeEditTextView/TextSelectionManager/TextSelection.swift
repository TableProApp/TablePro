//
//  TextSelection.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 8/20/24.
//

import Foundation
import AppKit

public extension TextSelectionManager {
    class TextSelection: Hashable, Equatable {
        public var range: NSRange
        weak var view: NSView?
        var boundingRect: CGRect = .zero
        var suggestedXPos: CGFloat?
        /// The position this selection should 'rotate' around when modifying selections.
        ///
        /// `public` so a subclass in another module implementing its own modifying motion can keep the same end
        /// fixed the built-in motions do. Without it such a motion has to guess the anchor from the direction, which
        /// makes the two directions both grow the selection instead of undoing each other.
        public var pivot: Int?

        init(range: NSRange, view: CursorView? = nil) {
            self.range = range
            self.view = view
        }

        var isCursor: Bool {
            range.length == 0
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(range)
        }

        public static func == (lhs: TextSelection, rhs: TextSelection) -> Bool {
            lhs.range == rhs.range
        }
    }
}

private extension TextSelectionManager.TextSelection {
    func didInsertText(length: Int, retainLength: Bool = false) {
        if !retainLength {
            range.length = 0
        }
        range.location += length
    }
}
