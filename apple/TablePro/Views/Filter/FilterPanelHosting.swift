//
//  FilterPanelHosting.swift
//  TablePro
//

import Foundation
import TableProPluginKit

@MainActor
internal protocol FilterPanelActions: AnyObject {
    func applyCheckedFilters()
    func applyFiltersInCurrentMode()
    func applyFilterAlone(_ filterID: UUID)
    func turnOffFilters()
    func removeFilter(_ filterID: UUID)
    func removeAllFilters()
    func closeFilterPanel()
    func focusGrid()
    func openFilterSettings()
}

@MainActor
internal protocol FilterSQLPreviewing: AnyObject {
    var filterPreviewDatabaseType: DatabaseType { get }
    func filterPreviewSQL() -> String
}

@MainActor
internal protocol FilterPresetStoring: AnyObject {
    func loadAllPresets() -> [FilterPreset]
    func savePreset(_ preset: FilterPreset) throws
    func deletePreset(_ preset: FilterPreset) throws
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
    var offersMatchAny = true
    var sqlPreview: (any FilterSQLPreviewing)?
    var presetStore: (any FilterPresetStoring)?
}
