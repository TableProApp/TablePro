//
//  WindowBrowseState.swift
//  TablePro
//

import Foundation

/// Where one window is browsing: what its sidebar lists, which row its workspace rail
/// highlights, and which container a tab opened from it lands in.
///
/// There is one of these per window, because that is the real cardinality. A connection has
/// one driver and one saved default, but it can have any number of windows open on any number
/// of its databases at once, and each of those windows is showing exactly one. Holding this on
/// `ConnectionSession` instead gave a connection one cursor for every window it owned, so the
/// last window to switch dragged all the others onto its database while their titles kept
/// naming the database they were actually showing. (#2088)
struct WindowBrowseState: Equatable {
    var database: String?
    var schema: String?

    /// A window that has not switched yet browses the connection's saved default, which is
    /// also where a fresh driver lands, so the two agree until the user moves one of them.
    static func seeded(database: String?, schema: String?) -> WindowBrowseState {
        WindowBrowseState(
            database: database.flatMap { $0.isEmpty ? nil : $0 },
            schema: schema.flatMap { $0.isEmpty ? nil : $0 }
        )
    }
}
