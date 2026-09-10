//
//  TextView+Layout.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 6/15/24.
//

import Foundation

extension TextView {
    override public func layout() {
        super.layout()
        layoutManager.layoutLines()
        selectionManager.updateSelectionViews(skipTimerReset: true)
    }

    open override class var isCompatibleWithResponsiveScrolling: Bool {
        true
    }

    open override func prepareContent(in rect: NSRect) {
        needsLayout = true
        super.prepareContent(in: rect)
    }

    /// `open` so a subclass in another module can paint its own decorations under the text. Everything drawn here
    /// lands beneath the line fragment views, so an override that paints before `super` sits under the caret line
    /// highlight and the selection as well.
    open override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if isSelectable {
            selectionManager.drawSelections(in: dirtyRect)
        }
        emphasisManager?.updateLayerBackgrounds()
    }

    override open var isFlipped: Bool {
        true
    }

    /// The part of the document the clip view shows, less anything the scroll view reserves over its leading and
    /// trailing edges, such as a gutter or a minimap floating there.
    ///
    /// `documentVisibleRect` includes the area under the clip view's content insets, so without this a caret sitting
    /// under the gutter counts as visible and is never scrolled out from under it.
    override public var visibleRect: NSRect {
        guard let scrollView else { return super.visibleRect }
        let insets = scrollView.contentView.contentInsets
        var rect = scrollView.documentVisibleRect
        rect.origin.x += insets.left
        rect.origin.y += insets.top
        rect.size.width = max(rect.width - insets.left - insets.right, 0)
        return rect.pixelAligned
    }

    /// The size of the scroll view's content area that its content insets leave uncovered.
    ///
    /// `NSScrollView.contentSize` does not subtract the content insets, so anything reserved over the edges of the clip
    /// view, a gutter on the leading side or a find panel along the top, is taken off here.
    var unobscuredContentSize: CGSize {
        guard let scrollView else { return .zero }
        let insets = scrollView.contentView.contentInsets
        return CGSize(
            width: max(scrollView.contentSize.width - insets.left - insets.right, 0),
            height: max(scrollView.contentSize.height - insets.top - insets.bottom, 0)
        )
    }

    public var visibleTextRange: NSRange? {
        layoutManager.textRange(covering: visibleRect)
    }

    public func updatedViewport(_ newRect: CGRect) {
        if !updateFrameIfNeeded() {
            layoutManager.layoutLines()
        }
        inputContext?.invalidateCharacterCoordinates()
    }

    /// Updates the view's frame if needed depending on wrapping lines, a new maximum width, or changed available size.
    /// - Returns: Whether or not the view was updated.
    @discardableResult
    public func updateFrameIfNeeded() -> Bool {
        let availableSize = unobscuredContentSize

        let extraHeight = availableSize.height * overscrollAmount
        let newHeight = max(layoutManager.estimatedHeight() + extraHeight, availableSize.height, 0)
        let newWidth = layoutManager.estimatedWidth()

        var didUpdate = false

        if newHeight >= availableSize.height && frame.size.height != newHeight {
            frame.size.height = newHeight
            // No need to update layout after height adjustment
        }

        if wrapLines && frame.size.width != availableSize.width {
            frame.size.width = availableSize.width
            didUpdate = true
        } else if !wrapLines && frame.size.width != max(newWidth, availableSize.width) {
            frame.size.width = max(newWidth, availableSize.width)
            didUpdate = true
        }

        if didUpdate {
            needsLayout = true
            needsDisplay = true
            layoutManager.setNeedsLayout()
        }

        if isSelectable {
            selectionManager?.updateSelectionViews()
        }

        return didUpdate
    }
}
