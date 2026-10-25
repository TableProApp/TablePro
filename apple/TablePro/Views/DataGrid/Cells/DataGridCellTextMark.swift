//
//  DataGridCellTextMark.swift
//  TablePro
//

import AppKit

// Drawn in the text's own color, so the mark survives selection, Dark Mode and Increase Contrast where a tint does not.
enum DataGridCellTextMark: Equatable {
    case struckThrough
    case underlined

    // A staged delete outranks the rest: the row is going away whatever was typed into it first.
    static func resolve(state: RowVisualState, columnIndex: Int) -> DataGridCellTextMark? {
        if state.isDeleted { return .struckThrough }
        if state.isInserted { return .underlined }
        if state.isStruck(columnIndex: columnIndex) { return .struckThrough }
        return state.isModified(columnIndex: columnIndex) ? .underlined : nil
    }

    // CTLineDraw draws both lines from the font's metrics and CTLineCreateTruncatedLine carries them onto the ellipsis.
    var attributes: [NSAttributedString.Key: Any] {
        switch self {
        case .struckThrough:
            return [.strikethroughStyle: NSUnderlineStyle.single.rawValue]
        case .underlined:
            return [.underlineStyle: NSUnderlineStyle.single.rawValue]
        }
    }

    // Resolved from the state, not the mark: one line covers a new row and an edited value, which a reader must tell apart.
    static func accessibilityDescription(state: RowVisualState, columnIndex: Int) -> String? {
        switch state.vocabulary {
        case .pendingEdit:
            if state.isDeleted { return String(localized: "marked for deletion") }
            if state.isInserted { return String(localized: "new row") }
            return state.isModified(columnIndex: columnIndex) ? String(localized: "edited") : nil
        case .comparison:
            if state.isDeleted { return String(localized: "only in the target") }
            if state.isInserted { return String(localized: "only in the source") }
            if state.isStruck(columnIndex: columnIndex) { return String(localized: "target value, differs") }
            return state.isModified(columnIndex: columnIndex) ? String(localized: "source value, differs") : nil
        case .resultComparison:
            if state.isDeleted { return String(localized: "only in the right result") }
            if state.isInserted { return String(localized: "only in the left result") }
            if state.isStruck(columnIndex: columnIndex) { return String(localized: "right value, differs") }
            return state.isModified(columnIndex: columnIndex) ? String(localized: "left value, differs") : nil
        }
    }
}
