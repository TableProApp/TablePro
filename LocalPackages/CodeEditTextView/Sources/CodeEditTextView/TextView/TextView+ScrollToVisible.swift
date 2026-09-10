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
        // estimated heights, which can be off by whole screens in a wrapped document, and answers a line an edit has
        // just invalidated with the line's start. So each pass lays out before it reads the rect: scrolling to an
        // edited line's start first would carry a view that was already showing the caret away from it.
        let offset = offsetNotPivot(selection)
        var lastFrame: CGRect = .zero
        let deadline = Date().addingTimeInterval(0.5)

        while Date() < deadline {
            layoutManager.layoutLines()
            guard let rect = layoutManager.rectForOffset(offset), rect != lastFrame else { break }
            lastFrame = rect
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
        guard let scrollView, let boundingRect = layoutManager.rectForOffset(range.location) else { return }

        if visibleRect.contains(boundingRect) {
            return
        }

        // Laying out changes line heights, which moves the offset we are scrolling to, so converge first.
        var lastFrame: CGRect = .zero
        let deadline = Date().addingTimeInterval(0.5)
        while let newRect = layoutManager.rectForOffset(range.location), lastFrame != newRect, Date() < deadline {
            lastFrame = newRect
            layoutManager.layoutLines()
            selectionManager.updateSelectionViews()
        }
        guard lastFrame != .zero else { return }

        // A rect the size of the unobscured viewport, placed where the range should end up. `scrollToVisible` then
        // moves the clip view just far enough to show all of it, which lands the range in place, and it stops at the
        // clip view's content insets and the document's edges, both of which a computed `scroll(to:)` ignores.
        let viewport = unobscuredContentSize
        let target = if center {
            CGRect(
                x: lastFrame.midX - viewport.width / 2,
                y: lastFrame.midY - viewport.height / 2,
                width: viewport.width,
                height: viewport.height
            )
        } else {
            CGRect(origin: lastFrame.origin, size: viewport)
        }
        scrollView.contentView.scrollToVisible(target)
        scrollView.reflectScrolledClipView(scrollView.contentView)
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
