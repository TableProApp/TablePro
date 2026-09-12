//
//  CompareStatusStyle.swift
//  TablePro
//
//  One vocabulary for a comparison outcome: a word, a symbol and a tint.
//
//  Colour is never the carrier on its own. Every call site pairs the tint with
//  the symbol and the word, and drops the tint when the system asks for shapes
//  instead of colour. Tints resolve through `ThemeEngine` rather than the
//  built-in `Color` literals, so a theme owns them the way it owns the grid.
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

    @MainActor
    internal static func tint(for status: TableDiffStatus) -> Color {
        let palette = ThemeEngine.shared.palette
        switch status {
        case .onlyInSource:
            return palette.color(.statusSuccess)
        case .onlyInTarget:
            return palette.color(.statusError)
        case .differs:
            return palette.color(.statusWarning)
        case .identical:
            return Color(nsColor: .secondaryLabelColor)
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
        }
    }

    @MainActor
    internal static func tint(for kind: RowDiffKind) -> Color {
        let palette = ThemeEngine.shared.palette
        switch kind {
        case .insert:
            return palette.color(.statusSuccess)
        case .update:
            return palette.color(.statusWarning)
        case .delete:
            return palette.color(.statusError)
        case .identical:
            return Color(nsColor: .secondaryLabelColor)
        }
    }

    /// The same tints the data grid paints an inserted, modified or deleted row with, so a row
    /// difference here reads the way the same row reads in the grid.
    @MainActor
    internal static func rowTint(for kind: RowDiffKind) -> Color {
        let palette = ThemeEngine.shared.palette
        switch kind {
        case .insert:
            return palette.color(.gridInserted)
        case .update:
            return palette.color(.gridModified)
        case .delete:
            return palette.color(.gridDeleted)
        case .identical:
            return .clear
        }
    }

    // MARK: - Message tints

    @MainActor
    internal static var warning: Color {
        ThemeEngine.shared.palette.color(.statusWarning)
    }

    @MainActor
    internal static var error: Color {
        ThemeEngine.shared.palette.color(.statusError)
    }

    @MainActor
    internal static var success: Color {
        ThemeEngine.shared.palette.color(.statusSuccess)
    }
}
