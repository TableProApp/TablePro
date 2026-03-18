//
//  LineFoldRibbonView.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 6/3/25.
//

import AppKit

extension LineFoldRibbonView {
    /// A helper type that determines if a fold should be drawn with a cap on the top or bottom if
    /// there's an adjacent fold on the same text line. It also provides a helper method to adjust fold rects using
    /// the cap information.
    struct FoldCapInfo {
        private let startIndices: Set<Int>
        private let endIndices: Set<Int>
        private let collapsedStartIndices: Set<Int>
        private let collapsedEndIndices: Set<Int>

        init(_ folds: [DrawingFoldInfo]) {
            var startIndices = Set<Int>()
            var endIndices = Set<Int>()
            var collapsedStartIndices = Set<Int>()
            var collapsedEndIndices = Set<Int>()

            for fold in folds {
                if fold.fold.isCollapsed {
                    collapsedStartIndices.insert(fold.startLine.index)
                    collapsedEndIndices.insert(fold.endLine.index)
                } else {
                    startIndices.insert(fold.startLine.index)
                    endIndices.insert(fold.endLine.index)
                }
            }

            self.startIndices = startIndices
            self.endIndices = endIndices
            self.collapsedStartIndices = collapsedStartIndices
            self.collapsedEndIndices = collapsedEndIndices
        }

        func foldNeedsTopCap(_ fold: DrawingFoldInfo) -> Bool {
            endIndices.contains(fold.startLine.index) || collapsedEndIndices.contains(fold.startLine.index)
        }

        func foldNeedsBottomCap(_ fold: DrawingFoldInfo) -> Bool {
            startIndices.contains(fold.endLine.index) || collapsedStartIndices.contains(fold.endLine.index)
        }

        func hoveredFoldShouldDrawTopChevron(_ fold: DrawingFoldInfo) -> Bool {
            !collapsedEndIndices.contains(fold.startLine.index)
        }

        func hoveredFoldShouldDrawBottomChevron(_ fold: DrawingFoldInfo) -> Bool {
            !collapsedStartIndices.contains(fold.endLine.index)
        }

        func adjustFoldRect(
            using fold: DrawingFoldInfo,
            rect: NSRect
        ) -> NSRect {
            let capTop = foldNeedsTopCap(fold)
            let capBottom = foldNeedsBottomCap(fold)
            let yDelta: CGFloat = if capTop && !collapsedEndIndices.contains(fold.startLine.index) {
                fold.startLine.height / 2.0
            } else {
                0.0
            }

            var heightDelta: CGFloat = 0.0
            if capTop && !collapsedEndIndices.contains(fold.startLine.index) {
                heightDelta -= fold.startLine.height / 2.0
            }
            if capBottom && !collapsedStartIndices.contains(fold.endLine.index) {
                heightDelta -= fold.endLine.height / 2.0
            }

            return NSRect(
                x: rect.origin.x,
                y: rect.origin.y + yDelta,
                width: rect.size.width,
                height: rect.size.height + heightDelta
            )
        }
    }
}
