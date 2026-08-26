//
//  TextView+ScrollToVisible.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 6/15/24.
//

import Foundation
import AppKit

extension TextView {
    fileprivate typealias Direction = TextSelectionManager.Direction
    fileprivate typealias TextSelection = TextSelectionManager.TextSelection

    /// Scrolls the moving end of the upmost selection into view, if `scrollView` is not `nil`.
    ///
    /// Follows the end that moved, never the selection's whole bounding rect. `scrollToVisible` only scrolls far
    /// enough to bring a rect into view, so once a selection grows past the height of the viewport its bounding
    /// rect already spans the visible area and the scroll becomes a no-op: extending further stops following.
    /// `NSTextView` scrolls to the moving end for the same reason.
    public func scrollSelectionToVisible() {
        guard let scrollView, let selection = getSelection() else {
            return
        }

        // Laying out changes line heights, which moves the offset we are scrolling to, so converge instead of
        // scrolling to the first estimate. `rectForOffset` answers a not-yet-laid-out line from the line storage's
        // estimated heights, which can be off by whole screens in a wrapped document.
        let offset = offsetNotPivot(selection)
        var lastFrame: CGRect = .zero
        let deadline = Date().addingTimeInterval(0.5)

        while let rect = layoutManager.rectForOffset(offset), lastFrame != rect, Date() < deadline {
            lastFrame = rect
            layoutManager.layoutLines()
            selectionManager.updateSelectionViews()
            scrollView.contentView.scrollToVisible(rect)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    /// Scrolls the view to the specified range.
    ///
    /// - Parameters:
    ///   - range: The range to scroll to.
    ///   - center: A flag that determines if the range should be centered in the view. Defaults to `true`.
    ///
    /// If `center` is `true`, the range will be centered in the visible area.
    /// If `center` is `false`, the range will be aligned at the top-left of the view.
    public func scrollToRange(_ range: NSRange, center: Bool = true) {
        guard let scrollView else { return }

        guard let boundingRect = layoutManager.rectForOffset(range.location) else { return }

        // Check if the range is already visible
        if visibleRect.contains(boundingRect) {
            return // No scrolling needed
        }

        // Calculate the target offset based on the center flag
        let targetOffset: CGPoint
        if center {
            targetOffset = CGPoint(
                x: max(boundingRect.midX - visibleRect.width / 2, 0),
                y: max(boundingRect.midY - visibleRect.height / 2, 0)
            )
        } else {
            targetOffset = CGPoint(
                x: max(boundingRect.origin.x, 0),
                y: max(boundingRect.origin.y, 0)
            )
        }

        var lastFrame: CGRect = .zero

        // Set a timeout to avoid an infinite loop
        let timeout: TimeInterval = 0.5
        let startTime = Date()

        // Adjust layout until stable
        while let newRect = layoutManager.rectForOffset(range.location),
              lastFrame != newRect,
              Date().timeIntervalSince(startTime) < timeout {
            lastFrame = newRect
            layoutManager.layoutLines()
            selectionManager.updateSelectionViews()
        }

        // Scroll to make the range appear at the desired position
        if lastFrame != .zero {
            let animated = false // feature flag
            if animated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.15 // Adjust duration as needed
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    scrollView.contentView.animator().setBoundsOrigin(targetOffset)
                }
            } else {
                scrollView.contentView.scroll(to: targetOffset)
            }
        }
    }

    /// Get the selection that should be scrolled to visible for the current text selection.
    /// - Returns: The the selection to scroll to.
    private func getSelection() -> TextSelection? {
        selectionManager
            .textSelections
            .sorted(by: { $0.range.max > $1.range.max }) // Get the lowest one.
            .first
    }

    /// Returns the offset that isn't the pivot of the selection.
    /// - Parameter selection: The selection to use.
    /// - Returns: The offset suitable for scrolling to.
    private func offsetNotPivot(_ selection: TextSelection) -> Int {
        guard let pivot = selection.pivot else {
            return selection.range.location
        }
        if selection.range.location == pivot {
            return selection.range.max
        } else {
            return selection.range.location
        }
    }
}
