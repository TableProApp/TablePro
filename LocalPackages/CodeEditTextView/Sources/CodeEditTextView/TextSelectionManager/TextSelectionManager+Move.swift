//
//  TextSelectionManager+Move.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 9/20/23.
//

import AppKit

extension TextSelectionManager {
    /// Moves all selections, determined by the direction and destination provided.
    ///
    /// Also handles updating the selection views and marks the view as needing display.
    ///
    /// - Parameters:
    ///   - direction: The direction to modify all selections.
    ///   - destination: The destination to move the selections by.
    ///   - modifySelection: Set to `true` to modify the selections instead of replacing it.
    public func moveSelections(
        direction: TextSelectionManager.Direction,
        destination: TextSelectionManager.Destination,
        modifySelection: Bool = false
    ) {
        textSelections.forEach {
            moveSelection(
                selection: $0,
                direction: direction,
                destination: destination,
                modifySelection: modifySelection
            )
        }
        updateSelectionViews()
        delegate?.setNeedsDisplay()
        NotificationCenter.default.post(Notification(name: Self.selectionChangedNotification, object: self))
    }

    /// Moves a single selection determined by the direction and destination provided.
    /// - Parameters:
    ///   - selection: The selection to modify.
    ///   - direction: The direction to move in.
    ///   - destination: The destination of the move.
    ///   - modifySelection: Set to `true` to modify the selection instead of replacing it.
    private func moveSelection(
        selection: TextSelectionManager.TextSelection,
        direction: TextSelectionManager.Direction,
        destination: TextSelectionManager.Destination,
        modifySelection: Bool = false
    ) {
        if !selection.range.isEmpty
            && !modifySelection
            && (direction == .backward || direction == .forward)
            && destination == .character {
            if direction == .forward {
                selection.range.location = selection.range.max
            }
            selection.range.length = 0
            return
        }

        // Update pivot if necessary
        if modifySelection {
            updateSelectionPivot(selection, direction: direction)
        }

        // Find where to modify the selection from.
        let startLocation = findSelectionStartLocation(
            selection,
            direction: direction,
            modifySelection: modifySelection
        )

        let range = rangeOfSelection(
            from: startLocation,
            direction: direction,
            destination: destination,
            suggestedXPos: selection.suggestedXPos
        )

        // Update the suggested x position
        updateSelectionXPos(selection, newRange: range, direction: direction, destination: destination)

        // Update the selection range
        updateSelectionRange(
            selection,
            newRange: range,
            modifySelection: modifySelection,
            direction: direction,
            destination: destination
        )
    }

    private func findSelectionStartLocation(
        _ selection: TextSelectionManager.TextSelection,
        direction: TextSelectionManager.Direction,
        modifySelection: Bool
    ) -> Int {
        if modifySelection {
            guard let pivot = selection.pivot else {
                assertionFailure("Pivot should always exist when modifying a selection.")
                return 0
            }
            switch direction {
            case .up, .forward:
                if pivot > selection.range.location {
                    return selection.range.location
                } else {
                    return selection.range.max
                }
            case .down, .backward:
                if pivot < selection.range.max {
                    return selection.range.max
                } else {
                    return selection.range.location
                }
            }
        } else {
            if direction == .forward || (direction == .down && !selection.range.isEmpty) {
                return selection.range.max
            } else {
                return selection.range.location
            }
        }
    }

    private func updateSelectionPivot(
        _ selection: TextSelectionManager.TextSelection,
        direction: TextSelectionManager.Direction
    ) {
        guard selection.pivot == nil else { return }
        switch direction {
        case .up:
            selection.pivot = selection.range.max
        case .down:
            selection.pivot = selection.range.location
        case .forward:
            selection.pivot = selection.range.location
        case .backward:
            selection.pivot = selection.range.max
        }
    }

    private func updateSelectionXPos(
        _ selection: TextSelectionManager.TextSelection,
        newRange range: NSRange,
        direction: TextSelectionManager.Direction,
        destination: TextSelectionManager.Destination
    ) {
        switch direction {
        case .up:
            if destination != .line {
                selection.suggestedXPos = selection.suggestedXPos ?? layoutManager?.rectForOffset(range.location)?.minX
            } else {
                selection.suggestedXPos = nil
            }
        case .down:
            if destination == .line {
                selection.suggestedXPos = layoutManager?.rectForOffset(range.max)?.minX
            } else {
                selection.suggestedXPos = selection.suggestedXPos ?? layoutManager?.rectForOffset(range.max)?.minX
            }
        case .forward:
            selection.suggestedXPos = layoutManager?.rectForOffset(range.max)?.minX
        case .backward:
            selection.suggestedXPos = layoutManager?.rectForOffset(range.location)?.minX
        }
    }

    private func updateSelectionRange(
        _ selection: TextSelectionManager.TextSelection,
        newRange range: NSRange,
        modifySelection: Bool,
        direction: TextSelectionManager.Direction,
        destination: TextSelectionManager.Destination
    ) {
        if modifySelection {
            guard let pivot = selection.pivot else {
                assertionFailure("Pivot should always exist when modifying a selection.")
                return
            }
            switch direction {
            case .down, .forward:
                if range.contains(pivot) {
                    selection.range.location = pivot
                    selection.range.length = range.length - (pivot - range.location)
                } else if pivot > selection.range.location {
                    selection.range.location += range.length
                    selection.range.length -= range.length
                } else {
                    selection.range.formUnion(range)
                }
            case .up, .backward:
                if range.contains(pivot) {
                    selection.range.location = range.location
                    selection.range.length = pivot - range.location
                } else if pivot < selection.range.max {
                    selection.range.length -= range.length
                } else {
                    selection.range.formUnion(range)
                }
            }
        } else {
            switch direction {
            case .up, .backward:
                selection.range = NSRange(location: range.location, length: 0)
                selection.pivot = range.location
            case .down, .forward:
                selection.range = NSRange(location: range.max, length: 0)
                selection.pivot = range.max
            }
        }
    }
}
