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
    case loading
    case failed(String)
    case noMatch
    case empty
    case list

    internal static func resolve(
        state: SchemaState,
        hasActiveFilter: Bool,
        hasAnyMatch: Bool,
        hasRoutines: Bool,
        hasTriggers: Bool
    ) -> SidebarObjectListPresentation {
        switch state {
        case .idle, .loading:
            return .loading
        case .failed(let message):
            return .failed(message)
        case .loaded(let tables):
            if hasActiveFilter, !hasAnyMatch {
                return .noMatch
            }
            if tables.isEmpty, !hasRoutines, !hasTriggers {
                return .empty
            }
            return .list
        }
    }
}
