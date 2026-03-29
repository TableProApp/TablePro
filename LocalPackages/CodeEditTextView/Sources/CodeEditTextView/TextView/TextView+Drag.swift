//
//  TextView+Drag.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 10/20/23.
//

import Foundation
import AppKit

private let pasteboardObjects = [NSString.self, NSURL.self]

extension TextView: NSDraggingSource {
    // MARK: - Drag Gesture

    /// Custom press gesture recognizer that fails if it does not click into a selected range.
    private class DragSelectionGesture: NSPressGestureRecognizer {
        override func mouseDown(with event: NSEvent) {
            guard isEnabled, let view = self.view as? TextView, event.type == .leftMouseDown else {
                return
            }

            let clickPoint = view.convert(event.locationInWindow, from: nil)
            let selectionRects = view.selectionManager.textSelections.filter({ !$0.range.isEmpty }).flatMap {
                view.selectionManager.getFillRects(in: view.frame, for: $0)
            }
            if !selectionRects.contains(where: { $0.contains(clickPoint) }) {
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
        dragGesture.isEnabled = isSelectable
        addGestureRecognizer(dragGesture)
    }

    /// Handles state change on the drag and drop gesture recognizer.
    ///
    /// This will ignore any gesture state besides `.began`, and will end by setting the state to `.ended`. The gesture
    /// is only meant to handle *recognizing* the drag, but the system drag interaction handles the rest.
    ///
    /// This will create a ``DraggingTextRenderer`` with the contents of the visible text selection. That is converted
    /// into an image and given to a new dragging session on the text view
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

        guard let visibleTextRange,
              let draggingView = DraggingTextRenderer(
                ranges: selectionManager.textSelections
                    .sorted(using: KeyPathComparator(\.range.location))
                    .compactMap { $0.range.intersection(visibleTextRange) },
                layoutManager: layoutManager
              ) else {
            return
        }

        guard let bitmap = bitmapImageRepForCachingDisplay(in: draggingView.frame) else {
            return
        }

        draggingView.cacheDisplay(in: draggingView.bounds, to: bitmap)

        guard let cgImage = bitmap.cgImage else {
            return
        }

        let draggingImage = NSImage(cgImage: cgImage, size: draggingView.intrinsicContentSize)

        let attributedStrings = selectionManager
            .textSelections
            .sorted(by: { $0.range.location < $1.range.location })
            .map { textStorage.attributedSubstring(from: $0.range) }
        let attributedString = NSMutableAttributedString()
        for (idx, string) in attributedStrings.enumerated() {
            attributedString.append(string)
            if idx < attributedStrings.count - 1 {
                attributedString.append(NSAttributedString(string: layoutManager.detectedLineEnding.rawValue))
            }
        }

        let draggingItem = NSDraggingItem(pasteboardWriter: attributedString)
        draggingItem.setDraggingFrame(draggingView.frame, contents: draggingImage)

        guard let currentEvent = NSApp.currentEvent else {
            return
        }

        beginDraggingSession(with: [draggingItem], event: currentEvent, source: self)
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
              objects.count > 0 else {
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
