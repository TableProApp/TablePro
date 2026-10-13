//
//  CompareStatusStyle.swift
//  TablePro
//
//  One vocabulary for a comparison outcome: a word, a symbol and a tint.
//
//  Colour is never the carrier on its own. Every call site pairs the tint with
//  the symbol and the word, and drops the tint when the system asks for shapes
//  instead of colour. The tints are system colours under every theme: a theme
//  colours only the SQL editor and the data grid.
//

import SwiftUI

internal enum CompareStatusStyle {
    internal static let notComparedTitle = String(localized: "Not compared")

    // MARK: - Object status

    internal static func title(for status: TableDiffStatus) -> String {
        switch status {
        case .onlyInSource:
            return String(localized: "Only in Source")
        case .onlyInTarget:
            return String(localized: "Only in Target")
        case .differs:
            return String(localized: "Differs")
        case .identical:
            return String(localized: "Identical")
        }
    }

    internal static func symbolName(for status: TableDiffStatus) -> String {
        switch status {
        case .onlyInSource:
            return "plus.circle"
        case .onlyInTarget:
            return "minus.circle"
        case .differs:
            return "circle.lefthalf.filled"
        case .identical:
            return "equal.circle"
        }
    }

    internal static func tint(for status: TableDiffStatus) -> Color {
        switch status {
        case .onlyInSource:
            return success
        case .onlyInTarget:
            return error
        case .differs:
            return warning
        case .identical:
            return .secondary
        }
    }

    // MARK: - Row difference

    internal static func title(for kind: RowDiffKind) -> String {
        switch kind {
        case .insert:
            return String(localized: "Insert")
        case .update:
            return String(localized: "Update")
        case .delete:
            return String(localized: "Delete")
        case .identical:
            return String(localized: "Same")
        case .conflict:
            return String(localized: "Outside Filter")
        }
    }

    internal static func symbolName(for kind: RowDiffKind) -> String {
        switch kind {
        case .insert:
            return "plus.circle.fill"
        case .update:
            return "circle.lefthalf.filled"
        case .delete:
            return "minus.circle.fill"
        case .identical:
            return "equal.circle"
        case .conflict:
            return "exclamationmark.triangle.fill"
        }
    }

    internal static func tint(for kind: RowDiffKind) -> Color {
        switch kind {
        case .insert:
            return success
        case .update, .conflict:
            return warning
        case .delete:
            return error
        case .identical:
            return .secondary
        }
    }

    /// The tints a data grid with no theme paints an inserted, modified or deleted row with, so a
    /// row difference reads the way the same row reads in the default grid. Not the grid's slots:
    /// a theme stops at the grid.
    internal static func rowTint(for kind: RowDiffKind) -> Color {
        switch kind {
        case .insert:
            return Color(nsColor: NativeThemeColors.insertedRow)
        case .update:
            return Color(nsColor: NativeThemeColors.modifiedRow)
        case .delete:
            return Color(nsColor: NativeThemeColors.deletedRow)
        case .identical, .conflict:
            return .clear
        }
    }

    // MARK: - Message tints

    internal static let warning = Color.orange
    internal static let error = Color.red
    internal static let success = Color.green
}
