//
//  FilterSettingsPage.swift
//  TablePro
//

import SwiftUI

struct FilterSettingsPage: View {
    @State private var settings = FilterSettingsStorage.shared.loadSettings()

    var body: some View {
        Form {
            Section {
                Picker("Default column", selection: $settings.defaultColumn) {
                    ForEach(FilterDefaultColumn.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }

                Picker("Default operator", selection: $settings.defaultOperator) {
                    ForEach(FilterDefaultOperator.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
            } header: {
                Text("New Rows")
            }

            Section {
                Picker(selection: $settings.restoreBehavior) {
                    ForEach(FilterRestoreBehavior.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                } label: {
                    Text("Saved filters")
                    Text(settings.restoreBehavior.settingsFooter)
                }

                Toggle("Always show the filter bar", isOn: $settings.alwaysShowPanel)
            } header: {
                Text("Reopening a Table")
            }
        }
        .formStyle(.grouped)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(SettingsPage.filters.pageIdentifier)
        .onChange(of: settings) { newValue in
            FilterSettingsStorage.shared.saveSettings(newValue)
        }
    }
}
