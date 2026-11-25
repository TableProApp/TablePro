//
//  FilterSettingsPage.swift
//  TablePro
//

import SwiftUI

struct FilterSettingsPage: View {
    // The filter bar's ⋯ menu writes the column order too, so the page reads the store rather than a copy.
    @ObservedObject private var storage = FilterSettingsStorage.shared

    private var settings: Binding<FilterSettings> {
        Binding(get: { storage.settings }, set: { storage.saveSettings($0) })
    }

    var body: some View {
        Form {
            Section {
                Picker("Default column", selection: settings.defaultColumn) {
                    ForEach(FilterDefaultColumn.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }

                Picker("Default operator", selection: settings.defaultOperator) {
                    ForEach(FilterDefaultOperator.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
            } header: {
                Text("New Rows")
            }

            Section {
                Picker("Column order", selection: settings.columnOrder) {
                    ForEach(FilterColumnOrder.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
            } header: {
                Text("Column Picker")
            }

            Section {
                Picker(selection: settings.restoreBehavior) {
                    ForEach(FilterRestoreBehavior.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                } label: {
                    Text("Saved filters")
                    Text(storage.settings.restoreBehavior.settingsFooter)
                }

                Toggle("Always show the filter bar", isOn: settings.alwaysShowPanel)
            } header: {
                Text("Reopening a Table")
            }
        }
        .formStyle(.grouped)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(SettingsPage.filters.pageIdentifier)
    }
}
