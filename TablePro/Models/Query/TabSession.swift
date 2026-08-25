//
//  TabSession.swift
//  TablePro
//

import Foundation
import Observation

/// The row buffer for one tab, and nothing else.
///
/// `QueryTab` is the whole of a tab's state: title, table context, filters, sort, pagination,
/// everything that is persisted. This class holds only what `QueryTab` deliberately does not: the
/// fetched rows. They live here because `QueryTab` is a value type inside an observed array, so
/// carrying tens of thousands of rows in it would copy them on every unrelated edit and re-render
/// the whole editor.
///
/// It used to mirror most of `QueryTab` as well, on the way to an architecture where views read
/// the reference type instead of the struct. That migration never happened. Nothing read the
/// mirrored copies, `QueryTabManager` only reconciled them on tab insert and removal, so pointing
/// a tab at another table left them describing the old one, and the ones that were kept in sync
/// were kept in sync for no reader (#2060).
@Observable @MainActor
final class TabSession: Identifiable {
    let id: UUID

    var tableRows: TableRows
    var isEvicted: Bool

    /// Bumped by `TabSessionRegistry` on every mutation of `tableRows`. `TableRows` is a
    /// value type with no `Equatable` conformance, so views that derive expensive content
    /// from it key their rebuild on this counter instead of on a proxy like the row count,
    /// which cannot distinguish two different results of the same size.
    var dataRevision: Int

    /// Bumped only when the buffer is replaced wholesale, which `dataRevision` cannot express: it
    /// also moves for an in-place edit, and a row id survives one of those. Row ids are positional,
    /// so a new page hands the same ids to different rows, and anything derived per row id has to
    /// be dropped exactly then and kept across an edit.
    var bufferEpoch: Int

    init(id: UUID = UUID()) {
        self.id = id
        self.tableRows = TableRows()
        self.isEvicted = false
        self.dataRevision = 0
        self.bufferEpoch = 0
    }
}
