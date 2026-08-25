//
//  DataGridDisplayState.swift
//  TablePro
//
//  The formatted-cell cache and viewport anchor a tab keeps while its grid is unmounted.
//

import AppKit
import Foundation

/// What a display cache was built from.
///
/// A cache that outlives its grid has to carry the inputs that decided its text, because nothing
/// invalidates it while no grid is mounted to notice them change.
struct DataGridDisplayIdentity: Equatable {
    let bufferEpoch: Int
    let resultSetId: UUID?
    let columns: [String]
    let columnTypes: [ColumnType]
    let displayFormats: [ValueDisplayFormat?]
    let dateFormat: DateFormatOption
    let nullDisplay: String
    let smartValueDetection: Bool
}

/// Whether the rows under a mounted grid were replaced, as opposed to the grid being rebuilt over
/// the same rows. A remount is not a content change and must not discard formatted text.
struct DataGridContentIdentity: Equatable {
    let reloadVersion: Int
    let contentRevision: Int
}

/// The per-result state a mounted grid derives, kept by an owner that outlives the view.
///
/// SwiftUI destroys `TableViewCoordinator` whenever the grid leaves the view tree, and the editor
/// mounts the grid as `.id(tab.id)`, so every tab switch threw away a whole result's formatted text
/// and rebuilt it: `CellDisplayFormatter` over every loaded row of every column, on the main actor,
/// growing with the rows the tab held. The owner keeps this the same way it already keeps the value
/// filter and the resolved display order. (#2424)
@MainActor
final class DataGridDisplayState {
    let cache = RowDisplayCache()
    var contentIdentity: DataGridContentIdentity?
    var firstVisibleRow: Int = 0
    /// The two derived values a coordinator compares against to decide the cache is stale. A fresh
    /// coordinator starts both empty, so without carrying them the first update of every remount
    /// reports a schema and a format change and clears the text it was just handed.
    var identitySchema: ColumnIdentitySchema?
    var displayFormats: [ValueDisplayFormat?]?
}
