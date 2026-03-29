//
//  TextLayoutManager+ensureLayout.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 4/7/25.
//

import AppKit

extension TextLayoutManager {
    /// Contains all data required to perform layout on a text line.
    private struct LineLayoutData {
        let minY: CGFloat
        let maxY: CGFloat
        let maxWidth: CGFloat
    }

    // MARK: - Layout Lines

    /// Lays out all visible lines
    ///
    /// ## Overview Of The Layout Routine
    ///
    /// The basic premise of this method is that it loops over all lines in the given rect (defaults to the visible
    /// rect), checks if the line needs a layout calculation, and performs layout on the line if it does.
    ///
    /// The thing that makes this layout method so fast is the second point, checking if a line needs layout. To
    /// determine if a line needs a layout pass, the layout manager can check three things:
    /// - **1** Was the line laid out under the assumption of a different maximum layout width?
    ///   For instance, if a line was previously broken by the line wrapping setting, it won’t need to wrap once the
    ///   line wrapping is disabled. This will detect that, and cause the lines to be recalculated.
    /// - **2** Was the line previously not visible? This is determined by keeping a set of visible line IDs. If the
    ///   line does not appear in that set, we can assume it was previously off screen and may need layout.
    /// - **3** Was the line entirely laid out? We break up lines into line fragments. When we do layout, we determine
    ///   all line fragments but don't necessarily place them all in the view. This checks if all line fragments have
    ///   been placed in the view. If not, we need to place them.
    ///
    /// Once it has been determined that a line needs layout, we perform layout by recalculating it's line fragments,
    /// removing all old line fragment views, and creating new ones for the line.
    ///
    /// ## Laziness
    ///
    /// At the end of the layout pass, we clean up any old lines by updating the set of visible line IDs and fragment
    /// IDs. Any IDs that no longer appear in those sets are removed to save resources. This facilitates the text view's
    /// ability to only render text that is visible and saves tons of resources (similar to the lazy loading of
    /// collection or table views).
    ///
    /// The other important lazy attribute is the line iteration. Line iteration is done lazily. As we iterate
    /// through lines and potentially update their heights, the next line is only queried for *after* the updates are
    /// finished.
    ///
    /// ## Reentry
    ///
    /// An important thing to note is that this method cannot be reentered. If a layout pass has begun while a layout
    /// pass is already ongoing, internal data structures will be broken. In debug builds, this is checked with a simple
    /// boolean and assertion.
    ///
    /// To help ensure this property, all view modifications are performed within a `CATransaction`. This guarantees
    /// that macOS calls `layout` on any related views only after we’ve finished inserting and removing line fragment
    /// views. Otherwise, inserting a line fragment view could trigger a layout pass prematurely and cause this method
    /// to re-enter.
    /// - Warning: This is probably not what you're looking for. If you need to invalidate layout, or update lines, this
    ///            is not the way to do so. This should only be called when macOS performs layout.
    @discardableResult
    public func layoutLines(in rect: NSRect? = nil) -> Set<TextLine.ID> { // swiftlint:disable:this function_body_length
        guard let visibleRect = rect ?? delegate?.visibleRect,
              !isInTransaction,
              let textStorage else {
            return []
        }

        // The macOS may call `layout` on the textView while we're laying out fragment views. This ensures the view
        // tree modifications caused by this method are atomic, so macOS won't call `layout` while we're already doing
        // that
        CATransaction.begin()
        layoutLock.lock()

        let minY = max(visibleRect.minY - verticalLayoutPadding, 0)
        let maxY = max(visibleRect.maxY + verticalLayoutPadding, 0)
        let originalHeight = lineStorage.height
        var usedFragmentIDs = Set<LineFragment.ID>()
        let forceLayout: Bool = needsLayout
        var didLayoutChange = false
        var newVisibleLines: Set<TextLine.ID> = []
        var yContentAdjustment: CGFloat = 0
        var maxFoundLineWidth = maxLineWidth

#if DEBUG
        var laidOutLines: Set<TextLine.ID> = []
#endif
        // Layout all lines, fetching lines lazily as they are laid out.
        for linePosition in linesStartingAt(minY, until: maxY).lazy {
            guard linePosition.yPos < maxY else { continue }
            // Three ways to determine if a line needs to be re-calculated.
            let linePositionNeedsLayout = linePosition.data.needsLayout(maxWidth: maxLineLayoutWidth)
            let wasNotVisible = !visibleLineIds.contains(linePosition.data.id)
            let lineNotEntirelyLaidOut = linePosition.height != linePosition.data.lineFragments.height

            defer { newVisibleLines.insert(linePosition.data.id) }

            func fullLineLayout() {
                let (yAdjustment, wasLineHeightChanged) = layoutLine(
                    linePosition,
                    usedFragmentIDs: &usedFragmentIDs,
                    textStorage: textStorage,
                    yRange: minY..<maxY,
                    maxFoundLineWidth: &maxFoundLineWidth
                )
                yContentAdjustment += yAdjustment
#if DEBUG
                laidOutLines.insert(linePosition.data.id)
#endif
                // If we've updated a line's height, or a line position was newly laid out, force re-layout for the
                // rest of the pass (going down the screen).
                //
                // These two signals identify:
                // - New lines being inserted & Lines being deleted (lineNotEntirelyLaidOut)
                // - Line updated for width change (wasLineHeightChanged)

                didLayoutChange = didLayoutChange || wasLineHeightChanged || lineNotEntirelyLaidOut
            }

            if forceLayout || linePositionNeedsLayout || wasNotVisible || lineNotEntirelyLaidOut {
                fullLineLayout()
            } else {
                if didLayoutChange || yContentAdjustment > 0 {
                    // Layout happened and this line needs to be moved but not necessarily re-added
                    let needsFullLayout = updateLineViewPositions(linePosition)
                    if needsFullLayout {
                        fullLineLayout()
                        continue
                    }
                }

                // Make sure the used fragment views aren't dequeued.
                usedFragmentIDs.formUnion(linePosition.data.lineFragments.map(\.data.id))
            }
        }

        // Enqueue any lines not used in this layout pass.
        viewReuseQueue.enqueueViews(notInSet: usedFragmentIDs)

        // Update the visible lines with the new set.
        visibleLineIds = newVisibleLines

        // The delegate methods below may call another layout pass, make sure we don't send it into a loop of forced
        // layout.
        needsLayout = false

        // Commit the view tree changes we just made.
        layoutLock.unlock()
        CATransaction.commit()

        if maxFoundLineWidth > maxLineWidth {
            maxLineWidth = maxFoundLineWidth
        }

        if yContentAdjustment != 0 {
            delegate?.layoutManagerYAdjustment(yContentAdjustment)
        }

        if originalHeight != lineStorage.height || layoutView?.frame.size.height != lineStorage.height {
            delegate?.layoutManagerHeightDidUpdate(newHeight: lineStorage.height)
        }

#if DEBUG
        return laidOutLines
#else
        return []
#endif
    }

    // MARK: - Layout Single Line

    private func layoutLine(
        _ linePosition: TextLineStorage<TextLine>.TextLinePosition,
        usedFragmentIDs: inout Set<LineFragment.ID>,
        textStorage: NSTextStorage,
        yRange: Range<CGFloat>,
        maxFoundLineWidth: inout CGFloat
    ) -> (CGFloat, wasLineHeightChanged: Bool) {
        let lineSize = layoutLineViews(
            linePosition,
            textStorage: textStorage,
            layoutData: LineLayoutData(minY: yRange.lowerBound, maxY: yRange.upperBound, maxWidth: maxLineLayoutWidth),
            laidOutFragmentIDs: &usedFragmentIDs
        )
        let wasLineHeightChanged = lineSize.height != linePosition.height
        var yContentAdjustment: CGFloat = 0.0

        if wasLineHeightChanged {
            lineStorage.update(
                atOffset: linePosition.range.location,
                delta: 0,
                deltaHeight: lineSize.height - linePosition.height
            )

            if linePosition.yPos < yRange.lowerBound {
                // Adjust the scroll position by the difference between the new height and old.
                yContentAdjustment += lineSize.height - linePosition.height
            }
        }
        if maxFoundLineWidth < lineSize.width {
            maxFoundLineWidth = lineSize.width
        }

        return (yContentAdjustment, wasLineHeightChanged)
    }

    /// Lays out a single text line.
    /// - Parameters:
    ///   - position: The line position from storage to use for layout.
    ///   - textStorage: The text storage object to use for text info.
    ///   - layoutData: The information required to perform layout for the given line.
    ///   - laidOutFragmentIDs: Updated by this method as line fragments are laid out.
    /// - Returns: A `CGSize` representing the max width and total height of the laid out portion of the line.
    private func layoutLineViews(
        _ position: TextLineStorage<TextLine>.TextLinePosition,
        textStorage: NSTextStorage,
        layoutData: LineLayoutData,
        laidOutFragmentIDs: inout Set<LineFragment.ID>
    ) -> CGSize {
        let lineDisplayData = TextLine.DisplayData(
            maxWidth: layoutData.maxWidth,
            lineHeightMultiplier: lineHeightMultiplier,
            estimatedLineHeight: estimateLineHeight(),
            breakStrategy: lineBreakStrategy
        )

        let line = position.data
        if let renderDelegate {
            renderDelegate.prepareForDisplay(
                textLine: line,
                displayData: lineDisplayData,
                range: position.range,
                stringRef: textStorage,
                markedRanges: markedTextManager.markedRanges(in: position.range),
                attachments: attachments.getAttachmentsStartingIn(position.range)
            )
        } else {
            line.prepareForDisplay(
                displayData: lineDisplayData,
                range: position.range,
                stringRef: textStorage,
                markedRanges: markedTextManager.markedRanges(in: position.range),
                attachments: attachments.getAttachmentsStartingIn(position.range)
            )
        }

        if position.range.isEmpty {
            return CGSize(width: 0, height: estimateLineHeight())
        }

        var height: CGFloat = 0
        var width: CGFloat = 0
        let relativeMinY = max(layoutData.minY - position.yPos, 0)
        let relativeMaxY = max(layoutData.maxY - position.yPos, relativeMinY)

//        for lineFragmentPosition in line.lineFragments.linesStartingAt(
//            relativeMinY,
//            until: relativeMaxY
//        ) {
        for lineFragmentPosition in line.lineFragments {
            let lineFragment = lineFragmentPosition.data
            lineFragment.documentRange = lineFragmentPosition.range.translate(location: position.range.location)

            layoutFragmentView(
                inLine: position,
                for: lineFragmentPosition,
                at: position.yPos + lineFragmentPosition.yPos
            )

            width = max(width, lineFragment.width)
            height += lineFragment.scaledHeight
            laidOutFragmentIDs.insert(lineFragment.id)
        }

        return CGSize(width: width, height: height)
    }

    // MARK: - Layout Fragment

    /// Lays out a line fragment view for the given line fragment at the specified y value.
    /// - Parameters:
    ///   - lineFragment: The line fragment position to lay out a view for.
    ///   - yPos: The y value at which the line should begin.
    private func layoutFragmentView(
        inLine line: TextLineStorage<TextLine>.TextLinePosition,
        for lineFragment: TextLineStorage<LineFragment>.TextLinePosition,
        at yPos: CGFloat
    ) {
        let fragmentRange = lineFragment.range.translate(location: line.range.location)
        let view = viewReuseQueue.getOrCreateView(forKey: lineFragment.data.id) {
            renderDelegate?.lineFragmentView(for: lineFragment.data) ?? LineFragmentView()
        }
        view.translatesAutoresizingMaskIntoConstraints = true // Small optimization for lots of subviews
        view.setLineFragment(lineFragment.data, fragmentRange: fragmentRange, renderer: lineFragmentRenderer)
        view.frame.origin = CGPoint(x: edgeInsets.left, y: yPos)
        layoutView?.addSubview(view, positioned: .below, relativeTo: nil)
        view.needsDisplay = true
    }

    private func updateLineViewPositions(_ position: TextLineStorage<TextLine>.TextLinePosition) -> Bool {
        let line = position.data
        for lineFragmentPosition in line.lineFragments {
            guard let view = viewReuseQueue.getView(forKey: lineFragmentPosition.data.id) else {
                return true
            }
            lineFragmentPosition.data.documentRange = lineFragmentPosition.range.translate(
                location: position.range.location
            )
            view.frame.origin = CGPoint(x: edgeInsets.left, y: position.yPos + lineFragmentPosition.yPos)
        }
        return false
    }
}
