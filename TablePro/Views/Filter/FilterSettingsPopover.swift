//
//  FilterSettingsPopover.swift
//  TablePro
//
//  Popover for filter default settings.
//  Extracted from FilterPanelView for better maintainability.
//

import SwiftUI

/// Popover for filter default settings
struct FilterSettingsPopover: View {
    @State private var settings: FilterSettings

    init() {
        _settings = State(initialValue: FilterSettingsStorage.shared.loadSettings())
    }

    var body: some View {
        Form {
            Picker("Default Column", selection: $settings.defaultColumn) {
                ForEach(FilterDefaultColumn.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }

            Picker("Default Operator", selection: $settings.defaultOperator) {
                ForEach(FilterDefaultOperator.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }

            Section {
                Picker("Saved Filters", selection: $settings.restoreBehavior) {
                    ForEach(FilterRestoreBehavior.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }

                Toggle("Always Show Filter Bar", isOn: $settings.alwaysShowPanel)
            } footer: {
                Text(settings.restoreBehavior.settingsFooter)
            }
        }
        .formStyle(.grouped)
        .frame(width: 320)
        .onChange(of: settings) { newValue in
            FilterSettingsStorage.shared.saveSettings(newValue)
        }
    }
}
