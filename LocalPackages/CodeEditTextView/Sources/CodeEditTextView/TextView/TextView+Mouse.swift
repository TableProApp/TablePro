//
//  TextView+Mouse.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 9/19/23.
//

import AppKit

extension TextView {
    override public func mouseDown(with event: NSEvent) {
        // Set cursor
        guard isSelectable,
              event.type == .leftMouseDown,
              let offset = layoutManager.textOffsetAtPoint(self.convert(event.locationInWindow, from: nil)) else {
            super.mouseDown(with: event)
            return
        }

        if let content = layoutManager.contentRun(at: offset),
           case let .attachment(attachment) = content.data, event.clickCount < 3 {
            handleAttachmentClick(event: event, offset: offset, attachment: attachment)
            return
        }

        mouseDragAnchor = self.convert(event.locationInWindow, from: nil)

        switch event.clickCount {
        case 1:
            handleSingleClick(event: event, offset: offset)
        case 2:
            handleDoubleClick(event: event, offset: offset)
        case 3:
            handleTripleClick(event: event, offset: offset)
        default:
            break
        }
    }

    /// The range a gesture at this offset anchors on, for the current selection granularity.
    func selectionRange(at offset: Int, for mode: CursorSelectionMode) -> NSRange {
        switch mode {
        case .character:
            return NSRange(location: offset, length: 0)
        case .word:
            return findWordBoundary(at: offset)
        case .line:
            return findLineBoundary(at: offset)
        }
    }

    /// Single click, if control-shift we add a cursor
    /// if shift, we extend the selection to the click location
    /// else we set the cursor
    fileprivate func handleSingleClick(event: NSEvent, offset: Int) {
        cursorSelectionMode = .character
        pendingCaretOffset = nil

        let eventFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if eventFlags == [.control, .shift] {
            guard isEditable else {
                super.mouseDown(with: event)
                return
            }
            unmarkText()
            selectionManager.addSelectedRange(NSRange(location: offset, length: 0))
            selectionDragAnchor = NSRange(location: offset, length: 0)
        } else if eventFlags.contains(.shift) {
            if isEditable {
                unmarkText()
            }
            shiftClickExtendSelection(to: offset)
        } else if selectionManager.textSelections.contains(where: { $0.range.contains(offset) }) {
            // Pressing inside the selection may be the start of a drag of that text, so leave the selection alone
            // and place the caret on mouse up if no drag follows.
            pendingCaretOffset = offset
        } else {
            selectionManager.setSelectedRange(NSRange(location: offset, length: 0))
            selectionDragAnchor = NSRange(location: offset, length: 0)
            selectionManager.textSelections.first?.pivot = offset
            if isEditable {
                unmarkTextIfNeeded()
            }
        }
    }

    /// Selects the word under the pointer.
    ///
    /// The boundary is found from the clicked offset rather than from the current selection, so a
    /// double click lands on the right word no matter what was selected before. The first click of
    /// the pair does not always reach ``handleSingleClick``: the drag gesture holds it back when it
    /// falls inside an existing selection, and a document swap can leave the view with no selection
    /// at all.
    fileprivate func handleDoubleClick(event: NSEvent, offset: Int) {
        if event.modifierFlags.contains(.shift) {
            extendSelection(to: offset, granularity: .word)
            return
        }
        if isEditable {
            unmarkText()
        }
        cursorSelectionMode = .word
        pendingCaretOffset = nil
        let wordRange = findWordBoundary(at: offset)
        selectionManager.setSelectedRange(wordRange)
        selectionDragAnchor = wordRange
        selectionManager.textSelections.first?.pivot = wordRange.location
    }

    fileprivate func handleTripleClick(event: NSEvent, offset: Int) {
        if event.modifierFlags.contains(.shift) {
            extendSelection(to: offset, granularity: .line)
            return
        }
        if isEditable {
            unmarkText()
        }
        cursorSelectionMode = .line
        pendingCaretOffset = nil
        let lineRange = findLineBoundary(at: offset)
        selectionManager.setSelectedRange(lineRange)
        selectionDragAnchor = lineRange
        selectionManager.textSelections.first?.pivot = lineRange.location
    }

    fileprivate func handleAttachmentClick(event: NSEvent, offset: Int, attachment: AnyTextAttachment) {
        switch event.clickCount {
        case 1:
            guard attachment.attachment.activatesOnSingleClick else {
                selectionManager.setSelectedRange(attachment.range)
                return
            }
            performAttachmentAction(attachment: attachment)
        case 2:
            performAttachmentAction(attachment: attachment)
        default:
            break
        }
    }

    func performAttachmentAction(attachment: AnyTextAttachment) {
        let action = attachment.attachment.attachmentAction()
        switch action {
        case .none:
            return
        case .discard:
            layoutManager.attachments.remove(atOffset: attachment.range.location)
            selectionManager.setSelectedRange(NSRange(location: attachment.range.location, length: 0))
        case let .replace(text):
            replaceCharacters(in: attachment.range, with: text)
        }
    }

    override public func mouseUp(with event: NSEvent) {
        if let pendingCaretOffset {
            selectionManager.setSelectedRange(NSRange(location: pendingCaretOffset, length: 0))
            selectionManager.textSelections.first?.pivot = pendingCaretOffset
            if isEditable {
                unmarkTextIfNeeded()
            }
        }
        pendingCaretOffset = nil
        mouseDragAnchor = nil
        selectionDragAnchor = nil
        disableMouseAutoscrollTimer()
        super.mouseUp(with: event)
    }

    override public func mouseDragged(with event: NSEvent) {
        guard !(inputContext?.handleEvent(event) ?? false) && isSelectable && !isDragging else {
            return
        }

        if let pendingCaretOffset {
            selectionDragAnchor = NSRange(location: pendingCaretOffset, length: 0)
            selectionManager.setSelectedRange(NSRange(location: pendingCaretOffset, length: 0))
            selectionManager.textSelections.first?.pivot = pendingCaretOffset
            self.pendingCaretOffset = nil
        }

        // We receive global events because our view received the drag event, but we need to clamp the potentially
        // out-of-bounds positions to a position our layout manager can deal with.
        let locationInView = convert(event.locationInWindow, from: nil)
        let clampedLocation = CGPoint(
            x: max(0.0, min(locationInView.x, frame.width)),
            y: max(0.0, min(locationInView.y, frame.height))
        )

        guard let mouseDragAnchor,
              let anchorRange = selectionDragAnchor,
              let endPosition = layoutManager.textOffsetAtPoint(clampedLocation) else {
            return
        }

        setUpMouseAutoscrollTimer()

        let modifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifierFlags.contains(.option) {
            dragColumnSelection(mouseDragAnchor: mouseDragAnchor, locationInView: clampedLocation)
        } else {
            dragSelection(from: anchorRange, to: endPosition)
        }
    }

    /// Extends the current selection to the offset. Only used when the user shift-clicks a location in the document.
    ///
    /// If the offset is within the selection, trims the selection from the nearest edge (start or end) towards the
    /// clicked offset.
    /// Otherwise, extends the selection to the clicked offset.
    ///
    /// - Parameter offset: The offset clicked on.
    fileprivate func shiftClickExtendSelection(to offset: Int) {
        // Use the last added selection, this is behavior copied from Xcode.
        guard let selection = selectionManager.textSelections.last else { return }
        // Move the free end and keep the anchor fixed, which is what `NSTextView` does and what makes a shift-click
        // that crosses the anchor reverse the selection instead of trimming the near edge. Fall back to the far end
        // for a selection whose anchor was never recorded.
        let anchor = selection.pivot ?? (offset > selection.range.location ? selection.range.location
                                                                           : selection.range.max)
        let extended = NSRange(start: min(anchor, offset), end: max(anchor, offset))
        selectionManager.setSelectedRange(extended)
        selectionManager.textSelections.first?.pivot = anchor
        selectionDragAnchor = NSRange(location: anchor, length: 0)
    }

    /// Extends the current selection to the offset, rounding both ends out to the given granularity.
    ///
    /// This is Shift+double-click and Shift+triple-click, which `NSTextView` answers by extending to whole words
    /// and whole paragraphs. Both used to fall through to `super.mouseDown`, so neither did anything.
    fileprivate func extendSelection(to offset: Int, granularity: CursorSelectionMode) {
        guard let selection = selectionManager.textSelections.last else { return }
        if isEditable {
            unmarkText()
        }
        cursorSelectionMode = granularity
        let anchorOffset = selection.pivot ?? (offset > selection.range.location ? selection.range.location
                                                                                : selection.range.max)
        let anchorRange = selectionRange(at: anchorOffset, for: granularity)
        selectionDragAnchor = anchorRange
        dragSelection(from: anchorRange, to: offset)
    }

    // MARK: - Mouse Autoscroll

    /// Sets up a timer that fires at a predetermined period to autoscroll the text view.
    /// Ensure the timer is disabled using ``disableMouseAutoscrollTimer``.
    func setUpMouseAutoscrollTimer() {
        guard mouseDragTimer == nil else { return }
        // The timer is the single autoscroll driver. `mouseDragged` deliberately does not scroll: the pointer
        // delivers drag events at whatever rate the input device runs at, so scrolling from there made the speed
        // track the device rather than the clock, and the timer used to scroll a second time for the same event.
        //
        // Scheduled in `.common` so it keeps firing inside the event tracking loop a drag runs in.
        // https://cocoadev.github.io/AutoScrolling/ (fired at ~45Hz)
        let timer = Timer(timeInterval: 0.022, repeats: true) { [weak self] _ in
            guard let self, let event = self.window?.currentEvent, event.type == .leftMouseDragged else { return }
            self.mouseDragged(with: event)
            self.autoscroll(with: event)
        }
        RunLoop.current.add(timer, forMode: .common)
        mouseDragTimer = timer
    }

    /// Disables the mouse drag timer started by ``setUpMouseAutoscrollTimer``
    func disableMouseAutoscrollTimer() {
        mouseDragTimer?.invalidate()
        mouseDragTimer = nil
    }

    // MARK: - Drag Selection

    /// Extends a drag selection from its anchor range to the offset under the pointer.
    ///
    /// The anchor range and the range under the pointer are unioned, which rounds both ends of the selection
    /// outward to the current granularity. That single rule is what `NSTextView` does, and it is why dragging back
    /// past the anchor keeps the anchor's whole word or line selected instead of splitting it.
    ///
    /// The anchor also becomes the selection's pivot, so a following Shift+Arrow moves the free end rather than
    /// guessing which end is live from the arrow's direction.
    private func dragSelection(from anchorRange: NSRange, to endPosition: Int) {
        let headRange = selectionRange(at: endPosition, for: cursorSelectionMode)
        let selectedRange = NSRange(
            start: min(anchorRange.location, headRange.location),
            end: max(anchorRange.max, headRange.max)
        )
        selectionManager.setSelectedRange(selectedRange)
        selectionManager.textSelections.first?.pivot = endPosition >= anchorRange.max
            ? anchorRange.location
            : anchorRange.max
    }

    private func dragColumnSelection(mouseDragAnchor: CGPoint, locationInView: CGPoint) {
        selectColumns(betweenPointA: mouseDragAnchor, pointB: locationInView)
    }
}
