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
    let actions: any FilterCriteriaActions

    var showsSort: Bool { sortColumns != nil }
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
}
