//
//  DataGridCellTextMark.swift
//  TablePro
//

import AppKit

/// The line a pending change draws through or under a cell's own text, the way Pages marks tracked
/// changes.
///
/// The tints alone could not carry this. A selected row paints over them, so a reader who selects
/// the rows they are about to save loses every mark at once, and a tint says nothing to a reader
/// who cannot see colour or is using a client that reads the grid rather than looking at it. The
/// line is drawn in the text's own colour, so it survives selection, Dark Mode, grayscale and
/// Increase Contrast, and the tints stay as the second cue.
enum DataGridCellTextMark: Equatable {
    /// A row staged for deletion, struck through as Pages strikes deleted text.
    case struckThrough
    /// A new row, or an edited cell, underlined as Pages underlines inserted text.
    case underlined

    /// What a pending change makes of a cell, or nil when nothing is staged for it.
    ///
    /// A staged delete outranks the rest: the row is going away whatever was typed into it first.
    static func resolve(state: RowVisualState, columnIndex: Int) -> DataGridCellTextMark? {
        if state.isDeleted { return .struckThrough }
        if state.isInserted { return .underlined }
        return state.isModified(columnIndex: columnIndex) ? .underlined : nil
    }

    /// Read by `CTLineDraw` itself, which draws both lines from the font's own metrics. Measured on
    /// macOS 27: a `CTLine` built from an attributed string carrying `.underlineStyle` or
    /// `.strikethroughStyle` draws that line, in the run's foreground colour, and
    /// `CTLineCreateTruncatedLine` carries it onto the truncated line. So the renderer never
    /// computes a line's position, thickness or width, and a cell that truncates is marked to
    /// exactly where its text ends.
    var attributes: [NSAttributedString.Key: Any] {
        switch self {
        case .struckThrough:
            return [.strikethroughStyle: NSUnderlineStyle.single.rawValue]
        case .underlined:
            return [.underlineStyle: NSUnderlineStyle.single.rawValue]
        }
    }

    /// What a client reading the grid is told, since a line it cannot see is no cue at all.
    ///
    /// Resolved from the state rather than from the mark, because one line covers two changes a
    /// reader needs told apart: a whole row that is new, and one edited value in a row that is not.
    static func accessibilityDescription(state: RowVisualState, columnIndex: Int) -> String? {
        if state.isDeleted { return String(localized: "marked for deletion") }
        if state.isInserted { return String(localized: "new row") }
        return state.isModified(columnIndex: columnIndex) ? String(localized: "edited") : nil
    }
}
