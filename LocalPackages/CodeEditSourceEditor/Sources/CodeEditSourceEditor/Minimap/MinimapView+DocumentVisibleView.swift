//
//  MinimapView+DocumentVisibleView.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 4/11/25.
//

import AppKit

extension MinimapView {
    /// Updates the ``documentVisibleView`` and ``scrollView`` to match the editor's scroll offset.
    ///
    /// - Note: In this context, the 'container' is the visible rect in the minimap.
    /// - Note: This is *tricky*, there's two cases for both views. If modifying, make sure to test both when the
    ///         minimap is shorter than the container height and when the minimap should scroll.
    ///
    /// The ``documentVisibleView`` uses a position that's entirely relative to the percent of the available scroll
    /// height scrolled. If the minimap is smaller than the container, it uses the same percent scrolled, but as a
    /// percent of the minimap height.
    ///
    /// The height of the ``documentVisibleView`` is calculated using a ratio of the editor's height to the
    /// minimap's height, then applying that to the container's height.
    ///
    /// The ``scrollView`` uses the scroll percentage calculated for the first case, and scrolls its content to that
    /// percentage. The ``scrollView`` is only modified if the minimap is longer than the container view.
    func updateDocumentVisibleViewPosition() {
        guard let textView = textView, let editorScrollView = textView.enclosingScrollView else {
            return
        }

        let availableHeight = min(minimapHeight, containerHeight)
        let editorScrollViewVisibleRect = (
            editorScrollView.documentVisibleRect.height - editorScrollView.contentInsets.vertical
        )
        let scrollPercentage = editorScrollView.percentScrolled
        guard scrollPercentage.isFinite else { return }

        let multiplier = if minimapHeight < containerHeight {
            editorScrollViewVisibleRect / textView.frame.height
        } else {
            editorToMinimapHeightRatio
        }

        // Update Visible Pane, should scroll down slowly as the user scrolls the document, following a similar pace
        // as the vertical `NSScroller`.
        // Visible pane's height   = visible height * multiplier
        // Visible pane's position = (container height - visible pane height) * scrollPercentage
        let visibleRectHeight = availableHeight * multiplier
        guard visibleRectHeight < 1e100 else { return }

        let availableContainerHeight = (availableHeight - visibleRectHeight)
        let visibleRectYPos = availableContainerHeight * scrollPercentage

        documentVisibleView.frame.origin.y = scrollView.contentInsets.top + visibleRectYPos
        documentVisibleView.frame.size.height = visibleRectHeight

        // Minimap scroll offset slowly scrolls down with the visible pane.
        if minimapHeight > containerHeight {
            setScrollViewPosition(scrollPercentage: scrollPercentage)
        }
    }

    private func setScrollViewPosition(scrollPercentage: CGFloat) {
        let totalHeight = contentView.frame.height + scrollView.contentInsets.vertical
        let visibleHeight = scrollView.documentVisibleRect.height
        let yPos = (totalHeight - visibleHeight) * scrollPercentage
        scrollView.contentView.scroll(
            to: NSPoint(
                x: scrollView.contentView.frame.origin.x,
                y: yPos - scrollView.contentInsets.top
            )
        )
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}
