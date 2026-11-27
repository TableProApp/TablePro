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
    func closeFilterPanel() {
        filterState.isVisible = false
        focusGrid()
    }

    func focusGrid() {
        gridModel.focus()
    }

    func openFilterSettings() {
        WindowOpener.shared.openSettings(SettingsLocation(page: .filters))
    }

    func addBlankFilter(columnName: String) {
        filterState.addFilter(forColumn: columnName, settings: FilterSettingsStorage.shared.settings)
    }
}
