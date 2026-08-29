//
//  CellEditorMovement.swift
//  TablePro
//

import Foundation

/// Which way an inline cell editor was left.
///
/// The cases are AppKit's own vocabulary for leaving one field for the next: `NSTextMovement`
/// declares `up` and `down` beside `tab` and `backtab` as "movement codes for movement between
/// fields". The overlay editor is a standalone text view rather than a field editor, so it reads
/// the four selectors itself and reports them here.
enum CellEditorMovement {
    case tab
    case backtab
    case up
    case down
}

/// Whether Up or Down in an inline cell editor moves the caret or leaves the cell.
///
/// A cell value can hold line breaks, so the arrow keys belong to the value's own lines first and
/// the editor is left only from the line at that end. A value on one line has no line to move to
/// in either direction, so both arrows leave it, including straight after the editor opens with
/// the whole value selected.
///
/// A line break is the only thing that starts a line here, because the overlay never wraps text
/// (`CellOverlayBase.applyCellTextLayout`, pinned by `CellOverlayTextLayoutTests`).
struct CellEditorArrowExit {
    let canExitUp: Bool
    let canExitDown: Bool

    init(text: NSString, selection: NSRange) {
        let length = text.length
        let start = min(max(selection.location, 0), length)
        let end = start + min(max(selection.length, 0), length - start)
        let breakAbove = Self.containsLineBreak(text, NSRange(location: 0, length: start))
        let breakBelow = Self.containsLineBreak(text, NSRange(location: end, length: length - end))

        guard start != end else {
            canExitUp = !breakAbove
            canExitDown = !breakBelow
            return
        }

        let isSingleLine = !breakAbove && !breakBelow
            && !Self.containsLineBreak(text, NSRange(location: start, length: end - start))
        canExitUp = isSingleLine
        canExitDown = isSingleLine
    }

    private static func containsLineBreak(_ text: NSString, _ range: NSRange) -> Bool {
        guard range.length > 0 else { return false }
        return text.rangeOfCharacter(from: .newlines, range: range).location != NSNotFound
    }
}
