//
//  SidebarObjectListPresentation.swift
//  TablePro
//

import Foundation

/// What the sidebar's object list should render for a given load state.
///
/// `.idle` means the schema has never been loaded for this connection, which is the state
/// every connection is in between connecting and the first fetch. It is not the same as a
/// database that genuinely has no objects, and telling the two apart is the whole reason
/// this lives outside the view.
internal enum SidebarObjectListPresentation: Equatable {
    /// Loading, and not yet for long enough to say so. An empty column is the placeholder the HIG
    /// asks for, and a local database answers in about 110ms, so a spinner there is a flash rather
    /// than a report.
    case preparing
    case loading
    case failed(String)
    case noMatch
    case empty
    case list

    /// `hasSideObjects` is whether any non-table kind returned rows: routines, triggers, types.
    /// A database with no tables but a stored procedure is a list, not an empty state.
    internal static func resolve(
        state: SchemaState,
        hasActiveFilter: Bool,
        hasAnyMatch: Bool,
        hasSideObjects: Bool,
        hasOutlastedGrace: Bool = true
    ) -> SidebarObjectListPresentation {
        switch state {
        case .idle, .loading:
            return hasOutlastedGrace ? .loading : .preparing
        case .failed(let message):
            return .failed(message)
        case .loaded(let tables):
            if hasActiveFilter, !hasAnyMatch {
                return .noMatch
            }
            if tables.isEmpty, !hasSideObjects {
                return .empty
            }
            return .list
        }
    }
}
