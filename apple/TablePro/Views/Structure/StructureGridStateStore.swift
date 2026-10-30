//
//  StructureGridStateStore.swift
//  TablePro
//

import Foundation
import TableProPluginKit

// One section's grid state. It never reaches a table's saved layout; only the columns a person hides are kept,
// per section, for every table.
@MainActor
final class StructureGridStateStore: DataGridStateStore {
    let section: StructureSection
    private let defaults: UserDefaults

    var sortState = SortState()
    var valueFilter = GridValueFilterState()
    var displayFormats: [ValueDisplayFormat?] = []
    var selectionSnapshot = GridSelectionSnapshot.empty
    var viewportAnchor: GridViewportPlacement?
    let layoutScope: DataGridLayoutScope = .ephemeral

    var columnLayout: ColumnLayoutState {
        didSet {
            guard columnLayout.hiddenColumns != oldValue.hiddenColumns else { return }
            defaults.set(Array(columnLayout.hiddenColumns).sorted(), forKey: Self.hiddenColumnsKey(section))
        }
    }

    init(section: StructureSection, defaults: UserDefaults = AppStorageEnvironment.shared.defaults) {
        self.section = section
        self.defaults = defaults
        var layout = ColumnLayoutState()
        if let stored = defaults.stringArray(forKey: Self.hiddenColumnsKey(section)) {
            layout.hiddenColumns = Set(stored)
        } else {
            layout.hiddenColumns = Self.defaultHiddenColumns(section)
        }
        columnLayout = layout
    }

    static func hiddenColumnsKey(_ section: StructureSection) -> String {
        "structure.hiddenColumns.\(section.rawValue)"
    }

    // The inspector edits every field; the table keeps the ones read at a glance.
    static func defaultHiddenColumns(_ section: StructureSection) -> Set<String> {
        switch section {
        case .columns:
            let hidden: [StructureColumnField] = [.onUpdate, .autoIncrement, .charset, .collation, .generated, .generationExpression]
            return Set(hidden.map(\.displayName))
        case .foreignKeys:
            return [String(localized: "Ref Schema")]
        case .indexes, .checkConstraints:
            return []
        }
    }
}
