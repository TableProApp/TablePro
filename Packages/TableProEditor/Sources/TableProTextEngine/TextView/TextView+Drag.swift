//
//  TextView+Drag.swift
//  TableProTextEngine
//
//  Created by Khan Winter on 10/20/23.
//

import AppKit
import Foundation

private let pasteboardObjects = [NSString.self, NSURL.self]

extension TextView: NSDraggingSource {
    // MARK: - Drag Gesture

    /// Custom press gesture recognizer that fails if it does not click into a selected range.
    private class DragSelectionGesture: NSPressGestureRecognizer {
        override func mouseDown(with event: NSEvent) {
            guard isEnabled, let view = self.view as? TextView, event.type == .leftMouseDown else {
                return
            }

            // A click is visible by definition.
            let clickPoint = view.convert(event.locationInWindow, from: nil)
            if !view.visibleSelectionFillRects().contains(where: { $0.rect.contains(clickPoint) }) {
                state = .failed
            }

            super.mouseDown(with: event)
        }
    }

    /// Adds a gesture for recognizing selection dragging gestures to the text view.
    /// See ``TextView/DragSelectionGesture`` for details.
    func setUpDragGesture() {
        let dragGesture = DragSelectionGesture(target: self, action: #selector(dragGestureHandler(_:)))
        dragGesture.minimumPressDuration = NSEvent.doubleClickInterval / 3
        // `NSPressGestureRecognizer` turns this on for itself, which withheld every primary mouse-down inside a
        // selection for the press duration: measured at 167ms of a completely dead pointer. The view no longer
        // needs the delay, because a press inside a selection defers its caret to mouse up rather than collapsing
        // the selection immediately, so there is nothing for the gesture to protect the selection from.
        dragGesture.delaysPrimaryMouseButtonEvents = false
        dragGesture.isEnabled = isSelectable
        addGestureRecognizer(dragGesture)
    }

    /// Handles state change on the drag and drop gesture recognizer.
    ///
    /// This will ignore any gesture state besides `.began`, and will end by setting the state to `.ended`. The gesture
    /// is only meant to handle *recognizing* the drag, but the system drag interaction handles the rest.
    ///
    /// The rest of the drag interaction is handled by ``performDragOperation(_:)``, ``draggingUpdated(_:)``,
    /// ``draggingSession(_:willBeginAt:)`` and family.
    ///
    /// - Parameter sender: The gesture that's sending the state change.
    @objc private func dragGestureHandler(_ sender: DragSelectionGesture) {
        guard sender.state == .began else { return }
        defer {
            sender.state = .ended
        }

        guard let currentEvent = NSApp.currentEvent, let draggingItem = makeSelectionDraggingItem() else {
            return
        }

        beginDraggingSession(with: [draggingItem], event: currentEvent, source: self)
    }

    /// The area of the view the user can see, or `.zero` when nothing is showing it.
    ///
    /// `NSView.visibleRect` answers `CGRect.infinite` for a view that isn't in a window, and a selection clipped to an
    /// infinite rect is as wide as the longest line in the document.
    private var onScreenRect: NSRect {
        visibleRect.isInfinite ? .zero : visibleRect
    }

    /// The parts of the text selections the user can see, in the text view's coordinate space.
    ///
    /// ``TextSelectionManager/fillRects(in:for:)`` clips to the rect it's given, so these are the rects the selection
    /// is highlighted in on screen. A press starts a drag when it lands in one of them, and the drag image covers
    /// them, so the user drags the highlight they pressed on.
    func visibleSelectionFillRects() -> [TextSelectionManager.FillRect] {
        selectionFillRects(in: onScreenRect)
    }

    private func selectionFillRects(in rect: NSRect) -> [TextSelectionManager.FillRect] {
        nonEmptySelections().flatMap { selectionManager.fillRects(in: rect, for: $0) }
    }

    /// The selections that have text in them, in document order.
    ///
    /// A selection that's only a caret is left out. It has nothing to drag, and joining it into the dragged text
    /// writes a blank line for every extra cursor.
    private func nonEmptySelections() -> [TextSelectionManager.TextSelection] {
        selectionManager
            .textSelections
            .filter { !$0.range.isEmpty }
            .sorted(using: KeyPathComparator(\.range.location))
    }

    /// The rects the drag image covers.
    ///
    /// The press that starts a drag lands inside the visible selection, but the view can scroll out from under it
    /// before the gesture recognizes. The image then covers the start of the selection in a box the size of the
    /// viewport, rather than the size of the document.
    private func draggingFillRects() -> [TextSelectionManager.FillRect] {
        let visibleFillRects = visibleSelectionFillRects()
        guard visibleFillRects.isEmpty else { return visibleFillRects }
        guard let selectionStart = nonEmptySelections()
            .first
            .flatMap({ layoutManager.rectForOffset($0.range.location) }) else {
            return []
        }
        return selectionFillRects(in: CGRect(origin: selectionStart.origin, size: onScreenRect.size))
    }

    /// Builds the item for a drag of the current selection: the text for the pasteboard, and the image the user drags.
    ///
    /// This will create a ``DraggingTextRenderer`` with the visible contents of the text selection. That is converted
    /// into an image and given to the item, positioned so it lines up with the text it was drawn from.
    ///
    /// - Returns: The item, or `nil` when there's no text selected or no image to draw.
    func makeSelectionDraggingItem() -> NSDraggingItem? {
        let selections = nonEmptySelections()
        guard !selections.isEmpty,
              let draggingView = DraggingTextRenderer(
                fillRects: draggingFillRects(),
                fragmentRenderer: layoutManager.lineFragmentRenderer
              ),
              let draggingImage = draggingView.drawnImage(scaledLike: self) else {
            return nil
        }

        let draggingItem = NSDraggingItem(pasteboardWriter: draggedText(for: selections))
        draggingItem.setDraggingFrame(draggingView.frame, contents: draggingImage)
        return draggingItem
    }

    private func draggedText(for selections: [TextSelectionManager.TextSelection]) -> NSAttributedString {
        let draggedText = NSMutableAttributedString()
        for (index, selection) in selections.enumerated() {
            draggedText.append(textStorage.attributedSubstring(from: selection.range))
            if index < selections.count - 1 {
                draggedText.append(NSAttributedString(string: layoutManager.detectedLineEnding.rawValue))
            }
        }
        return draggedText
    }

    // MARK: - NSDraggingSource

    public func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .outsideApplication ? .copy : .move
    }

    public func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        if let draggingCursorView {
            draggingCursorView.removeFromSuperview()
            self.draggingCursorView = nil
        }
        isDragging = true
        pendingCaretOffset = nil
        setUpMouseAutoscrollTimer()
    }

    /// Updates the text view about a dragging session. The text view will update the ``TextView/draggingCursorView``
    /// cursor to match the drop destination depending on where the drag is on the text view.
    ///
    /// The text view will not place a dragging cursor view when the dragging destination is in an existing
    /// text selection.
    /// - Parameters:
    ///   - session: The dragging session that was updated.
    ///   - screenPoint: The position on the screen where the drag exists.
    public func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        guard let windowCoordinates = self.window?.convertPoint(fromScreen: screenPoint) else {
            return
        }

        let viewPoint = self.convert(windowCoordinates, from: nil) // Converts from window
        let cursor: NSView

        if let draggingCursorView {
            cursor = draggingCursorView
        } else if useSystemCursor, #available(macOS 15, *) {
            let systemCursor = NSTextInsertionIndicator()
            cursor = systemCursor
            systemCursor.displayMode = .visible
            addSubview(cursor)
        } else {
            cursor = CursorView(color: selectionManager.insertionPointColor)
            addSubview(cursor)
        }

        self.draggingCursorView = cursor

        guard let documentOffset = layoutManager.textOffsetAtPoint(viewPoint),
              let cursorPosition = layoutManager.rectForOffset(documentOffset) else {
            return
        }

        // Don't show a cursor in selected areas
        guard !selectionManager.textSelections.contains(where: { $0.range.contains(documentOffset) }) else {
            draggingCursorView?.removeFromSuperview()
            draggingCursorView = nil
            return
        }

        cursor.frame.origin = cursorPosition.origin
        cursor.frame.size.height = cursorPosition.height
    }

    public func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        if let draggingCursorView {
            draggingCursorView.removeFromSuperview()
            self.draggingCursorView = nil
        }
        isDragging = false
        disableMouseAutoscrollTimer()
    }

    override public func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        determineDragOperation(sender)
    }

    override public func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        determineDragOperation(sender)
    }

    private func determineDragOperation(_ dragInfo: any NSDraggingInfo) -> NSDragOperation {
        let canReadObjects = dragInfo.draggingPasteboard.canReadObject(forClasses: pasteboardObjects)

        guard canReadObjects else {
            return NSDragOperation()
        }

        if let currentEvent = NSApplication.shared.currentEvent, currentEvent.modifierFlags.contains(.option) {
            return .copy
        }

        return .move
    }

    // MARK: - Perform Drag

    /// Performs the final drop operation.
    ///
    /// This method accepts a number of items from the dragging info's pasteboard, and cuts them into the
    /// destination determined by the ``TextView/draggingCursorView``.
    ///
    /// If the app's current event has the `option` key pressed, this will only paste the text from the pasteboard,
    /// and not remove the original dragged text.
    ///
    /// - Parameter sender: The dragging info to use.
    /// - Returns: `true`, if the drag was accepted.
    override public func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let objects = sender.draggingPasteboard.readObjects(forClasses: pasteboardObjects)?
            .compactMap({ anyObject in
                if let object = anyObject as? NSString {
                    return String(object)
                } else if let object = anyObject as? NSURL, let string = object.absoluteString {
                    return String(string)
                }
                return nil
            }),
              !objects.isEmpty else {
            return false
        }
        let insertionString = objects.joined(separator: layoutManager.detectedLineEnding.rawValue)

        // Grab the insertion location
        guard let draggingCursorView,
              var insertionOffset = layoutManager.textOffsetAtPoint(draggingCursorView.frame.origin) else {
            // There was no active drag
            return false
        }

        let shouldCutSourceText = !(NSApplication.shared.currentEvent?.modifierFlags.contains(.option) ?? false)

        undoManager?.beginUndoGrouping()

        if shouldCutSourceText, let source = sender.draggingSource as? TextView, source === self {
            // Offset the insertion location so that we can remove the text first before pasting it into the editor.
            var updatedInsertionOffset = insertionOffset
            for selection in source.selectionManager.textSelections.reversed()
            where selection.range.location < insertionOffset {
                if selection.range.upperBound > insertionOffset {
                    updatedInsertionOffset -= insertionOffset - selection.range.location
                } else {
                    updatedInsertionOffset -= selection.range.length
                }
            }
            insertionOffset = updatedInsertionOffset
            insertText("") // Replace the selected ranges with nothing
        }

        replaceCharacters(in: [NSRange(location: insertionOffset, length: 0)], with: insertionString)

        undoManager?.endUndoGrouping()

        selectionManager.setSelectedRange(
            NSRange(location: insertionOffset, length: NSString(string: insertionString).length)
        )

        return true
    }
}
