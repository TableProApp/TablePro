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
///
/// A loaded database is always a list, whatever it holds. The outline says per section what is
/// missing, so a database with no tables keeps its Procedures, Functions and Triggers, and keeps
/// the Tables section whose menu is where a first table gets created.
internal enum SidebarObjectListPresentation: Equatable {
    /// Loading, and not yet for long enough to say so. An empty column is the placeholder the HIG
    /// asks for, and a local database answers in about 110ms, so a spinner there is a flash rather
    /// than a report.
    case preparing
    case loading
    case failed(String)
    case noMatch
    case list

    /// The schema tree draws its own no-match state, so only the load itself is resolved for it.
    /// Reaching for the state enum directly instead is what left the tree with a spinner on no gate
    /// at all, flashing it on every engine that groups by schema while the two flat shapes beside
    /// it held theirs back.
    internal static func resolveDeferringEmptyStates(
        state: SchemaState,
        hasOutlastedGrace: Bool = true
    ) -> SidebarObjectListPresentation {
        resolve(
            state: state,
            hasActiveFilter: false,
            hasAnyMatch: true,
            hasOutlastedGrace: hasOutlastedGrace
        )
    }

    internal static func resolve(
        state: SchemaState,
        hasActiveFilter: Bool,
        hasAnyMatch: Bool,
        hasOutlastedGrace: Bool = true
    ) -> SidebarObjectListPresentation {
        switch state {
        case .idle, .loading:
            return hasOutlastedGrace ? .loading : .preparing
        case .failed(let message):
            return .failed(message)
        case .loaded:
            if hasActiveFilter, !hasAnyMatch {
                return .noMatch
            }
            return .list
        }
    }
}
