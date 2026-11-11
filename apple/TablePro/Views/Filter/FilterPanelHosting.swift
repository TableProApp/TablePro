//
//  FilterPanelHosting.swift
//  TablePro
//

import Foundation
import TableProPluginKit

@MainActor
internal protocol FilterPanelActions: AnyObject {
    func applyAllFilters()
    func applySoloFilter(_ filter: TableFilter)
    func clearAppliedFiltersAndReload()
    func removeAllFiltersAndReload()
    func closeFilterPanel()
    func focusGrid()
}

internal extension FilterPanelActions {
    func reload(after outcome: TabFilterState.RemoveFilterOutcome) {
        switch outcome {
        case .noChange:
            return
        case .clear:
            clearAppliedFiltersAndReload()
        case .reapply:
            applyAllFilters()
        }
    }
}

@MainActor
internal protocol FilterSQLPreviewing: AnyObject {
    var filterPreviewDatabaseType: DatabaseType { get }
    func filterPreviewSQL() -> String
}

@MainActor
internal protocol FilterPresetStoring: AnyObject {
    func loadAllPresets() -> [FilterPreset]
    func savePreset(_ preset: FilterPreset)
    func deletePreset(_ preset: FilterPreset)
}

extension FilterPresetStorage: FilterPresetStoring {}

/// What a panel that holds the sort as well asks of its host.
@MainActor
internal protocol FilterCriteriaActions: AnyObject {
    /// Runs the panel's rows and its sort draft in one reload.
    func applyFiltersAndSort()
    /// The condition these rows produce, without the WHERE keyword: empty when none is complete,
    /// nil when one cannot be written for this engine.
    func filterConditionText(for filters: [TableFilter], logicMode: FilterLogicMode) -> String?
}

/// The Builder | Text switch, the Sort By section and the combined Apply, for a table tab under
/// `DataGridSettings.showsSortInFilterPanel`.
internal struct FilterCriteriaConfiguration {
    /// Text mode needs a WHERE condition the engine runs as written.
    var offersTextMode: Bool
    /// Nil on an engine that cannot order a table by a column, which hides the section.
    var sortColumns: [String]?
    /// The tab's sort, which the section shows until it is edited.
    var appliedSort: [FilterSortCriterion]
    var newSortDirection: SortDirection
    /// The WHERE condition the rows on screen were fetched with, as Text mode writes it. Nil outside
    /// Text mode, and where those rows cannot be written as one condition.
    var runningCondition: String?
    let actions: any FilterCriteriaActions

    var showsSort: Bool { sortColumns != nil }

    /// Whether Apply Filter & Sort would fetch rows other than the ones on screen, which is when the
    /// header says Criteria Edited.
    func isEdited(_ state: TabFilterState) -> Bool {
        state.criteriaDiffer(fromAppliedSort: appliedSort, runningCondition: runningCondition)
    }

    /// Apply Filter & Sort asks for a press only while pressing it would fetch other rows. Once the
    /// rows on screen match the panel it is a plain bordered button, enabled by the same rules.
    func applyIsProminent(for state: TabFilterState) -> Bool {
        isEdited(state)
    }
}

internal struct FilterPanelConfiguration {
    var columns: [String]
    var primaryKeyColumn: String?
    var enumValuesByColumn: [String: [String]] = [:]
    var fieldPaths: [PluginFieldPath] = []
    var valueCompletionKeywords: [String] = []
    var offersRawFilter: Bool
    var rawFilterLabel = String(localized: "Raw SQL")
    var rawSQLCompletionProvider: RawSQLFilterCompletionProvider?
    var caseMatching: FilterCaseMatching
    var offersMatchAny = true
    var sqlPreview: (any FilterSQLPreviewing)?
    var presetStore: (any FilterPresetStoring)?
    /// Nil draws the filter-only panel.
    var criteria: FilterCriteriaConfiguration?
    /// Whether a filter brought in from outside the panel (a cell's Filter menu, Filter with Column)
    /// replaces the empty row the panel opened with while the reader has not touched it.
    var replacesUntouchedStartingRow = false
}
