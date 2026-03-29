//
//  TextView+ColumnSelection.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 6/19/25.
//

import AppKit

extension TextView {
    /// Set the user's selection to a square region in the editor.
    ///
    /// This method will automatically determine a valid region from the provided two points.
    /// - Parameters:
    ///   - pointA: The first point.
    ///   - pointB: The second point.
    public func selectColumns(betweenPointA pointA: CGPoint, pointB: CGPoint) {
        let start = CGPoint(x: min(pointA.x, pointB.x), y: min(pointA.y, pointB.y))
        let end = CGPoint(x: max(pointA.x, pointB.x), y: max(pointA.y, pointB.y))

        // Collect all overlapping text ranges
        var selectedRanges: [NSRange] = layoutManager.linesStartingAt(start.y, until: end.y).flatMap { textLine in
            // Collect fragment ranges
            return textLine.data.lineFragments.compactMap { lineFragment -> NSRange? in
                let startOffset = self.layoutManager.textOffsetAtPoint(
                    start,
                    fragmentPosition: lineFragment,
                    linePosition: textLine
                )
                let endOffset = self.layoutManager.textOffsetAtPoint(
                    end,
                    fragmentPosition: lineFragment,
                    linePosition: textLine
                )
                guard let startOffset, let endOffset else { return nil }

                return NSRange(start: startOffset, end: endOffset)
            }
        }

        // If we have some non-cursor selections, filter out any cursor selections
        if selectedRanges.contains(where: { !$0.isEmpty }) {
            selectedRanges = selectedRanges.filter({
                !$0.isEmpty || (layoutManager.rectForOffset($0.location)?.origin.x.approxEqual(start.x) ?? false)
            })
        }

        selectionManager.setSelectedRanges(selectedRanges)
    }
}
