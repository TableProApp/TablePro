//
//  QueryEditorBarLayout.swift
//  TablePro
//

import Foundation

/// One control of the query bar. The bar draws exactly the controls its rows name, so which ones a
/// layout holds is decided here, where a test can read it without mounting the view.
internal enum QueryEditorBarControl: Hashable, Sendable {
    case database
    case vimMode
    /// Format and Save as Favorite, side by side as one group: the single-row bar's editing tools.
    case editingCommands
    case ai
    case explain
    /// Run with its menu while idle, Stop while a query is in flight.
    case run
    case save
    case separator
    case queryBuilder
    case format
    case snippets
    case connection
}

/// A row of the bar: controls from the leading edge, a flexible gap, then controls against the
/// trailing edge.
internal struct QueryEditorBarRow: Equatable, Sendable {
    internal var leading: [QueryEditorBarControl]
    internal var trailing: [QueryEditorBarControl]
}

/// Which controls the query bar holds and on which row.
///
/// One row is the bar as it always was. Two rows split it by what a control acts on: the first row
/// edits the query (Save, Query Builder, Format, Snippets, AI), the second names where it runs and
/// runs it (connection, database, Explain, Run). Save as Favorite moves into the Snippets menu there,
/// beside the saved queries it adds to.
internal enum QueryEditorBarLayout {
    internal static func rows(
        twoRows: Bool,
        showsQueryBuilder: Bool,
        showsAI: Bool,
        showsVimMode: Bool
    ) -> [QueryEditorBarRow] {
        let vimMode: [QueryEditorBarControl] = showsVimMode ? [.vimMode] : []
        let ai: [QueryEditorBarControl] = showsAI ? [.ai] : []
        guard twoRows else {
            return [QueryEditorBarRow(
                leading: [.database] + vimMode,
                trailing: [.editingCommands] + ai + [.explain, .run]
            )]
        }
        let queryBuilder: [QueryEditorBarControl] = showsQueryBuilder ? [.queryBuilder] : []
        return [
            QueryEditorBarRow(
                leading: [.save, .separator] + queryBuilder + [.format, .snippets] + ai,
                trailing: []
            ),
            QueryEditorBarRow(
                leading: [.connection, .database] + vimMode,
                trailing: [.explain, .run]
            ),
        ]
    }
}

/// The hue each editing tool of the two-row bar wears in the colorful icon style, the way the toolbar's
/// Objects buttons each wear one, so the run reads at a glance. The standard style and every control of
/// the second row stay monochrome.
internal enum QueryEditorBarToolTint {
    internal static func tint(for control: QueryEditorBarControl, style: ObjectIconStyle) -> ObjectIconTint? {
        guard style == .colorful else { return nil }
        switch control {
        case .save: return .blue
        case .queryBuilder: return .orange
        case .format: return .purple
        case .snippets: return .teal
        case .ai: return .pink
        case .database, .vimMode, .editingCommands, .explain, .run, .separator, .connection: return nil
        }
    }
}
