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
    func filterPreviewSQL() -> String
}

@MainActor
internal protocol FilterPresetStoring: AnyObject {
    func loadAllPresets() -> [FilterPreset]
    func savePreset(_ preset: FilterPreset)
    func deletePreset(_ preset: FilterPreset)
}

extension FilterPresetStorage: FilterPresetStoring {}

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
    var sqlPreview: (any FilterSQLPreviewing)?
    var presetStore: (any FilterPresetStoring)?
}
