//
//  DataFileFilterPanel.swift
//  TablePro
//

import SwiftUI

struct DataFileFilterPanel: View {
    @ObservedObject var controller: DataFileController

    var body: some View {
        FilterPanelView(
            state: $controller.filterState,
            configuration: FilterPanelConfiguration(
                columns: controller.columnNames.displayNames,
                primaryKeyColumn: nil,
                offersRawFilter: false,
                caseMatching: .inMemory,
                sqlPreview: nil,
                presetStore: FilterPresetStorage.shared
            ),
            actions: controller
        )
    }
}

extension DataFileController: FilterPanelActions {
    func clearAppliedFiltersAndReload() {
        filterState.commit = nil
        runQuery()
    }

    func removeAllFiltersAndReload() {
        filterState.filters = []
        filterState.commit = nil
        runQuery()
    }

    func closeFilterPanel() {
        filterState.isVisible = false
        focusGrid()
    }

    func focusGrid() {
        guard let tableView = gridCoordinator?.tableView else { return }
        tableView.window?.makeFirstResponder(tableView)
    }

    func addBlankFilter(columnName: String) {
        filterState.addFilter(forColumn: columnName, settings: FilterSettingsStorage.shared.loadSettings())
    }
}
