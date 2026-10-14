//
//  CompareStatusStyle.swift
//  TablePro
//
//  Colour is never the carrier on its own: every call site pairs the tint with the symbol and the
//  word, and drops the tint when the system asks for shapes instead of colour.
//

import AppKit
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

    // MARK: - Changed lines

    /// The grid's own row tints, so a changed line reads like the same row in the grid under any theme.
    internal static func rowTintColor(for kind: RowDiffKind, palette: ThemePalette) -> NSColor? {
        switch kind {
        case .insert:
            return palette.color(.gridInserted, otherwise: NativeThemeColors.insertedRow)
        case .update:
            return palette.color(.gridModified, otherwise: NativeThemeColors.modifiedRow)
        case .delete:
            return palette.color(.gridDeleted, otherwise: NativeThemeColors.deletedRow)
        case .identical, .conflict:
            return nil
        }
    }

    internal static func rowTint(for kind: RowDiffKind, palette: ThemePalette) -> Color {
        rowTintColor(for: kind, palette: palette).map { Color(nsColor: $0) } ?? .clear
    }

    private static func gridSlot(for kind: RowDiffKind) -> ThemeSlot? {
        switch kind {
        case .insert: return .gridInserted
        case .update: return .gridModified
        case .delete: return .gridDeleted
        case .identical, .conflict: return nil
        }
    }

    /// For a diff whose own tint differs from the grid's: the theme's tint wins only where it sets one.
    @MainActor
    internal static func lineTint(
        for kind: RowDiffKind,
        native: Color,
        engine: ThemeEngine = .shared,
        contrast: ColorSchemeContrast
    ) -> Color {
        guard let slot = gridSlot(for: kind) else { return native }
        return ThemeShapeStyle.override(slot, engine: engine, contrast: contrast) ?? native
    }

    /// A line tinted as deleted takes the grid's deleted-row text, the way that row reads in the grid.
    @MainActor
    internal static func lineTextOverride(
        for kind: RowDiffKind?,
        engine: ThemeEngine = .shared,
        contrast: ColorSchemeContrast
    ) -> Color? {
        if kind == .delete, let deleted = ThemeShapeStyle.override(.gridDeletedText, engine: engine, contrast: contrast) {
            return deleted
        }
        return ThemeShapeStyle.override(.editorText, engine: engine, contrast: contrast)
    }

    // MARK: - Message tints

    internal static let warning = Color.orange
    internal static let error = Color.red
    internal static let success = Color.green
}

private struct DiffLineForeground: ViewModifier {
    @ObservedObject private var themeEngine = ThemeEngine.shared
    @Environment(\.colorSchemeContrast) private var contrast

    let kind: RowDiffKind?

    func body(content: Content) -> some View {
        content.foregroundStyle(style)
    }

    private var style: AnyShapeStyle {
        guard let color = CompareStatusStyle.lineTextOverride(for: kind, engine: themeEngine, contrast: contrast) else {
            return AnyShapeStyle(HierarchicalShapeStyle.primary)
        }
        return AnyShapeStyle(color)
    }
}

internal extension View {
    /// Not for a selectable row: a theme color does not flip to white on the emphasized selection.
    func diffLineForeground(_ kind: RowDiffKind?) -> some View {
        modifier(DiffLineForeground(kind: kind))
    }
}
