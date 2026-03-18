//
//  LineFoldRibbonView.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 5/6/25.
//

import Foundation
import AppKit
import CodeEditTextView

/// Displays the code folding ribbon in the ``GutterView``.
///
/// This view draws its contents manually. This was chosen over managing views on a per-fold basis, which would come
/// with needing to manage view reuse and positioning. Drawing allows this view to draw only what macOS requests, and
/// ends up being extremely efficient. This does mean that animations have to be done manually with a timer.
/// Re: the `hoveredFold` property.
class LineFoldRibbonView: NSView {
    struct HoverAnimationDetails: Equatable {
        var fold: FoldRange?
        var foldMask: CGPath?
        var timer: Timer?
        var progress: CGFloat = 0.0

        static let empty = HoverAnimationDetails()

        public static func == (_ lhs: HoverAnimationDetails, _ rhs: HoverAnimationDetails) -> Bool {
            lhs.fold == rhs.fold && lhs.foldMask == rhs.foldMask && lhs.progress == rhs.progress
        }
    }

    static let width: CGFloat = 7.0

    var model: LineFoldModel?

    @Invalidating(.display)
    var hoveringFold: HoverAnimationDetails = .empty

    @Invalidating(.display)
    var backgroundColor: NSColor = NSColor.controlBackgroundColor

    @Invalidating(.display)
    var markerColor = NSColor(
        light: NSColor(deviceWhite: 0.0, alpha: 0.1),
        dark: NSColor(deviceWhite: 1.0, alpha: 0.2)
    ).cgColor

    @Invalidating(.display)
    var markerBorderColor = NSColor(
        light: NSColor(deviceWhite: 1.0, alpha: 0.4),
        dark: NSColor(deviceWhite: 0.0, alpha: 0.4)
    ).cgColor

    @Invalidating(.display)
    var hoverFillColor = NSColor(
        light: NSColor(deviceWhite: 1.0, alpha: 1.0),
        dark: NSColor(deviceWhite: 0.17, alpha: 1.0)
    ).cgColor

    @Invalidating(.display)
    var hoverBorderColor = NSColor(
        light: NSColor(deviceWhite: 0.8, alpha: 1.0),
        dark: NSColor(deviceWhite: 0.4, alpha: 1.0)
    ).cgColor

    @Invalidating(.display)
    var foldedIndicatorColor = NSColor(
        light: NSColor(deviceWhite: 0.0, alpha: 0.3),
        dark: NSColor(deviceWhite: 1.0, alpha: 0.6)
    ).cgColor

    @Invalidating(.display)
    var foldedIndicatorChevronColor = NSColor(
        light: NSColor(deviceWhite: 1.0, alpha: 1.0),
        dark: NSColor(deviceWhite: 0.0, alpha: 1.0)
    ).cgColor

    override public var isFlipped: Bool {
        true
    }

    init(controller: TextViewController) {
        super.init(frame: .zero)
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        clipsToBounds = false
        self.model = LineFoldModel(
            controller: controller,
            foldView: self
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override public func resetCursorRects() {
        // Don't use an iBeam in this view
        addCursorRect(bounds, cursor: .arrow)
    }

    // MARK: - Hover

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeInKeyWindow, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        self.mouseMoved(with: event)
    }

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        let clickPoint = convert(event.locationInWindow, from: nil)
        guard let layoutManager = model?.controller?.textView.layoutManager,
              event.type == .leftMouseDown,
              let lineNumber = layoutManager.textLineForPosition(clickPoint.y)?.index,
              let fold = model?.getCachedFoldAt(lineNumber: lineNumber),
              let firstLineInFold = layoutManager.textLineForOffset(fold.range.lowerBound) else {
            super.mouseDown(with: event)
            return
        }

        if let attachment = findAttachmentFor(fold: fold, firstLineRange: firstLineInFold.range) {
            layoutManager.attachments.remove(atOffset: attachment.range.location)
        } else {
            let charWidth = model?.controller?.font.charWidth ?? 1.0
            let placeholder = LineFoldPlaceholder(delegate: model, fold: fold, charWidth: charWidth)
            layoutManager.attachments.add(placeholder, for: NSRange(fold.range))
        }

        model?.foldCache.toggleCollapse(forFold: fold)
        model?.controller?.textView.needsLayout = true
        model?.controller?.gutterView.needsDisplay = true
        mouseMoved(with: event)
    }

    private func findAttachmentFor(fold: FoldRange, firstLineRange: NSRange) -> AnyTextAttachment? {
        model?.controller?.textView?.layoutManager.attachments
            .getAttachmentsStartingIn(NSRange(fold.range))
            .filter({
                $0.attachment is LineFoldPlaceholder && firstLineRange.contains($0.range.location)
            }).first
    }

    override func mouseMoved(with event: NSEvent) {
        defer {
            super.mouseMoved(with: event)
        }

        let pointInView = convert(event.locationInWindow, from: nil)
        guard let lineNumber = model?.controller?.textView.layoutManager.textLineForPosition(pointInView.y)?.index,
              let fold = model?.getCachedFoldAt(lineNumber: lineNumber),
              !fold.isCollapsed else {
            clearHoveredFold()
            return
        }

        guard fold.range != hoveringFold.fold?.range else {
            return
        }

        setHoveredFold(fold: fold)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        clearHoveredFold()
    }

    /// Clears the current hovered fold. Does not animate.
    func clearHoveredFold() {
        hoveringFold = .empty
        model?.clearEmphasis()
    }

    /// Set the current hovered fold. This method determines when an animation is required and will facilitate it.
    /// - Parameter fold: The fold to set as the current hovered fold.
    func setHoveredFold(fold: FoldRange) {
        defer {
            model?.emphasizeBracketsForFold(fold)
        }

        hoveringFold.timer?.invalidate()
        // We only animate the first hovered fold. If the user moves the mouse vertically into other folds we just
        // show it immediately.
        if hoveringFold.fold == nil {
            let duration: TimeInterval = 0.2
            let startTime = CACurrentMediaTime()

            hoveringFold = HoverAnimationDetails(
                fold: fold,
                timer: Timer.scheduledTimer(withTimeInterval: 1/60, repeats: true) { [weak self] timer in
                    guard let self = self else { return }
                    let now = CACurrentMediaTime()
                    let time = CGFloat((now - startTime) / duration)
                    self.hoveringFold.progress = min(1.0, time)
                    if self.hoveringFold.progress >= 1.0 {
                        timer.invalidate()
                    }
                }
            )
            return
        }

        // Don't animate these
        hoveringFold = HoverAnimationDetails(fold: fold, progress: 1.0)
    }
}
