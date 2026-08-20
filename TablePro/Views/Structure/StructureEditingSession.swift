//
//  StructureEditingSession.swift
//  TablePro
//

import Foundation
import Observation
import TableProPluginKit

/// The staged structure edits for one table, held outside the view that presents them.
///
/// `MainEditorContentView` builds only the selected tab's content, and the results view mode is a
/// `switch` inside that, so switching tabs and switching a tab between Data and Structure both tear
/// the view down and take its `@State` with it. Staged ALTERs are the user's work and have to
/// outlive that, the same way a table tab's data-grid edits already do.
///
/// The loaded schema travels with them, and not as an optimisation. `StructureChangeManager`
/// adopts a new baseline through `loadSchema`, which clears every pending change, the validation
/// errors and the undo stack, so a rebuild that refetched the schema would discard the edits on its
/// way back in. Holding the baseline here is what lets the rebuild skip the fetch, and skipping the
/// fetch is the only version of this that keeps the edits.
@MainActor
@Observable
internal final class StructureEditingSession {
    /// The scope and table this session was opened against. A tab retargeted to another table gets
    /// a new session rather than inheriting edits staged against the old one.
    internal let identity: String

    internal let changeManager = StructureChangeManager()

    internal var columns: [ColumnInfo] = []
    internal var indexes: [IndexInfo] = []
    internal var foreignKeys: [ForeignKeyInfo] = []
    internal var triggers: [TriggerInfo] = []
    internal var ddlStatement: String = ""
    internal var tabData = StructureTabDataState()

    /// Whether the opening fetch has already run. True only after a real load, so a rebuild adopts
    /// what is here instead of refetching, while a genuine refresh still goes through
    /// `onRefreshData`, which asks before discarding.
    internal var hasLoaded = false

    internal init(identity: String) {
        self.identity = identity
    }
}
