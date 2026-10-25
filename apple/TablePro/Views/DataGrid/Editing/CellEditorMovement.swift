//
//  CellEditorMovement.swift
//  TablePro
//

import Foundation

// NSTableView never moves editing between view-based cells itself (probe P1c), so the grid does, in these steps.
enum CellEditorMovement: Equatable {
    case tab
    case backtab
    case up
    case down
}

// Up and Down belong to a value's own lines first and leave the cell only from the line at that end (#2569).
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
