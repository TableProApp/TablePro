//
//  TextLayoutManager+ensureLayout.swift
//  TableProTextEngine
//
//  Created by Khan Winter on 4/7/25.
//

import AppKit

/// Grows `span` to cover `range`, starting it there when it covers nothing yet.
private func extend(_ span: inout NSRange?, with range: NSRange) {
    guard let current = span else {
        span = range
        return
    }
    span = NSRange(start: Swift.min(current.location, range.location), end: Swift.max(current.max, range.max))
}

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
    /// - **3** Does the line's stored height disagree with the height of its line fragments? A line an edit inserted
    ///   or merged is stored at an estimated height until it is typeset, so a mismatch means it needs layout.
    ///
    /// Once it has been determined that a line needs layout, we perform layout by recalculating it's line fragments
    /// and placing views for the ones inside the layout rect.
    ///
    /// ## Line Fragment Views
    ///
    /// A line is typeset as a whole, because its height is the height of every one of its fragments, but only the
    /// fragments that intersect the layout rect get a view. A wrapped line can be many times taller than the viewport
    /// and stay visible while the viewport scrolls across it without ever needing layout, so every pass also places
    /// views for the fragments of such a line that moved into the rect, and leaves the ones that moved out of it to be
    /// reused. The number of fragment views follows the height of the layout rect, never the length of a line.
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
    public func layoutLines(in rect: NSRect? = nil) -> Set<TextLine.ID> {
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
        var didLineHeightChange = false
        var newVisibleLines: Set<TextLine.ID> = []
        var yContentAdjustment: CGFloat = 0

        // The vertical span this pass laid out. The layout view draws its own decorations into a backing store
        // nothing else invalidates when the viewport moves, so a band drawn before its lines were laid out would
        // stay blank forever. Tracked as a span rather than a rect because a rect union silently drops an operand
        // of zero width, which is what an unparented layout view reports.
        var relaidOutMinY: CGFloat = .greatestFiniteMagnitude
        var relaidOutMaxY: CGFloat = -.greatestFiniteMagnitude

        // The same two spans in document offsets, for a delegate that keeps geometry over the text rather than
        // pixels in a backing store. `laidOutOffsets` covers every line the pass visited, which is where geometry
        // can be read; `relaidOutOffsets` covers the lines it measured again, which is where geometry has moved.
        var laidOutOffsets: NSRange?
        var relaidOutOffsets: NSRange?

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

            defer {
                newVisibleLines.insert(linePosition.data.id)
                extend(&laidOutOffsets, with: linePosition.range)
            }

            guard forceLayout || linePositionNeedsLayout || wasNotVisible || lineNotEntirelyLaidOut else {
                // The line keeps its fragments, but a line above it may have moved it and the viewport may have
                // moved across it, so its views still have to match the layout rect.
                layoutFragmentViews(
                    of: linePosition,
                    in: minY..<maxY,
                    redrawingPlacedViews: false,
                    laidOutFragmentIDs: &usedFragmentIDs
                )
                continue
            }

            let (yAdjustment, wasLineHeightChanged) = layoutLine(
                linePosition,
                usedFragmentIDs: &usedFragmentIDs,
                textStorage: textStorage,
                yRange: minY..<maxY
            )
            yContentAdjustment += yAdjustment
            extend(&relaidOutOffsets, with: linePosition.range)
            relaidOutMinY = min(relaidOutMinY, linePosition.yPos)
            relaidOutMaxY = max(
                relaidOutMaxY,
                linePosition.yPos + max(linePosition.height, linePosition.data.lineFragments.height)
            )
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

            // Narrower than `didLayoutChange` on purpose. That one is also true of a line laid out for the
            // first time, which asks the rest of the pass to re-place its views; only a height that changed
            // moves the lines below it. Geometry kept over the text follows this signal, or one newly revealed
            // line re-measures every emphasis below it on every frame of a scroll.
            didLineHeightChange = didLineHeightChange || wasLineHeightChanged
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

        if maxLineWidth != lineStorage.maxWidth {
            maxLineWidth = lineStorage.maxWidth
        }

        if yContentAdjustment != 0 {
            delegate?.layoutManagerYAdjustment(yContentAdjustment)
        }

        if originalHeight != lineStorage.height || layoutView?.frame.size.height != lineStorage.height {
            delegate?.layoutManagerHeightDidUpdate(newHeight: lineStorage.height)
        }

        if let layoutView, relaidOutMinY <= relaidOutMaxY {
            // A height change or a y adjustment moves every line below the first one this pass touched.
            let movedEverythingBelow = didLayoutChange || yContentAdjustment != 0
            let bottom = movedEverythingBelow ? max(maxY, relaidOutMaxY) : relaidOutMaxY
            layoutView.setNeedsDisplay(
                CGRect(
                    x: 0,
                    y: relaidOutMinY,
                    width: layoutView.frame.width,
                    height: bottom - relaidOutMinY
                )
            )
        }

        reportLayout(
            relaidOut: relaidOutOffsets,
            laidOut: laidOutOffsets,
            movedEverythingBelow: didLineHeightChange || yContentAdjustment != 0,
            ySpan: minY...Swift.max(minY, maxY)
        )

#if DEBUG
        return laidOutLines
#else
        return []
#endif
    }

    /// Tells the delegate what this pass laid out and what it moved.
    ///
    /// Runs after the layout lock and the `CATransaction`, beside the other delegate calls, because the internal
    /// data structures are final at that point and a delegate that lays out again cannot break line storage.
    /// - Parameters:
    ///   - relaidOut: The span of text this pass measured again, `nil` if it measured none.
    ///   - laidOut: The span of text this pass visited, `nil` if it visited none.
    ///   - movedEverythingBelow: Whether a height change or a scroll adjustment moved every line below `relaidOut`,
    ///                           including the ones this pass never visited.
    ///   - ySpan: The vertical span this pass laid out.
    private func reportLayout(
        relaidOut: NSRange?,
        laidOut: NSRange?,
        movedEverythingBelow: Bool,
        ySpan: ClosedRange<CGFloat>
    ) {
        if let relaidOut {
            if movedEverythingBelow {
                invalidateGeometry(from: relaidOut.location)
            } else {
                invalidateGeometry(in: relaidOut)
            }
        }

        // Cleared only once it has been handed over. A pass that runs with no delegate keeps accumulating, since
        // the lines it laid out will not be laid out again to raise the same invalidation a second time.
        guard let delegate else { return }
        let invalidatedRange = pendingGeometryInvalidation
        pendingGeometryInvalidation = nil
        delegate.layoutManagerDidLayout(
            TextLayoutUpdate(invalidatedRange: invalidatedRange, laidOutRange: laidOut, laidOutYSpan: ySpan)
        )
    }

    // MARK: - Layout Single Line

    private func layoutLine(
        _ linePosition: TextLineStorage<TextLine>.TextLinePosition,
        usedFragmentIDs: inout Set<LineFragment.ID>,
        textStorage: NSTextStorage,
        yRange: Range<CGFloat>
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
        lineStorage.setWidth(lineSize.width, forLineAt: linePosition.index)

        return (yContentAdjustment, wasLineHeightChanged)
    }

    /// Lays out a single text line.
    /// - Parameters:
    ///   - position: The line position from storage to use for layout.
    ///   - textStorage: The text storage object to use for text info.
    ///   - layoutData: The information required to perform layout for the given line.
    ///   - laidOutFragmentIDs: Updated by this method as line fragments are laid out.
    /// - Returns: A `CGSize` representing the max width and total height of the whole line. Fragments outside the
    ///            layout rect count too, even though they get no view, because the line storage records this size as
    ///            the line's own.
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
            breakStrategy: lineBreakStrategy,
            specialCharacterStyle: specialCharacterStyle
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

        var width: CGFloat = 0
        for lineFragmentPosition in line.lineFragments {
            let lineFragment = lineFragmentPosition.data
            lineFragment.documentRange = lineFragmentPosition.range.translate(location: position.range.location)
            width = max(width, lineFragment.width)
        }

        layoutFragmentViews(
            of: position,
            in: layoutData.minY..<layoutData.maxY,
            redrawingPlacedViews: true,
            laidOutFragmentIDs: &laidOutFragmentIDs
        )

        return CGSize(width: width, height: line.lineFragments.height)
    }

    // MARK: - Layout Fragment

    /// Places a view for every fragment of a line that intersects a vertical band, and none for the rest.
    ///
    /// A fragment that already has a view keeps it, moved to where the line now puts it. When the line has just been
    /// typeset, `redrawingPlacedViews` hands those views their fragment again and redraws them. A fragment outside the
    /// band is left out of `laidOutFragmentIDs`, so the end of the layout pass releases its view for reuse.
    /// - Parameters:
    ///   - position: The line position whose fragments to place.
    ///   - yRange: The vertical band being laid out, in the layout view's coordinate space.
    ///   - redrawingPlacedViews: Whether a fragment that already has a view is drawn again.
    ///   - laidOutFragmentIDs: Updated with the fragments that have a view.
    private func layoutFragmentViews(
        of position: TextLineStorage<TextLine>.TextLinePosition,
        in yRange: Range<CGFloat>,
        redrawingPlacedViews: Bool,
        laidOutFragmentIDs: inout Set<LineFragment.ID>
    ) {
        guard !position.range.isEmpty else { return }
        let relativeMinY = max(yRange.lowerBound - position.yPos, 0)
        let relativeMaxY = max(yRange.upperBound - position.yPos, relativeMinY)

        for lineFragmentPosition in position.data.lineFragments.linesStartingAt(relativeMinY, until: relativeMaxY) {
            let lineFragment = lineFragmentPosition.data
            let yPos = position.yPos + lineFragmentPosition.yPos
            lineFragment.documentRange = lineFragmentPosition.range.translate(location: position.range.location)
            laidOutFragmentIDs.insert(lineFragment.id)

            if !redrawingPlacedViews, let view = viewReuseQueue.getView(forKey: lineFragment.id) {
                view.frame.origin = CGPoint(x: edgeInsets.left, y: yPos)
            } else {
                layoutFragmentView(inLine: position, for: lineFragmentPosition, at: yPos)
            }
        }
    }

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
}
