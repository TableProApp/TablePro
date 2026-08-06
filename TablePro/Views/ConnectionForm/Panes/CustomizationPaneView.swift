//
//  CustomizationPaneView.swift
//  TablePro
//

import SwiftUI

struct CustomizationPaneView: View {
    @Bindable var coordinator: ConnectionFormCoordinator

    var body: some View {
        Form {
            Section(String(localized: "Appearance")) {
                LabeledContent(String(localized: "Color")) {
                    ConnectionColorPicker(selectedColor: $coordinator.customization.color)
                }
                LabeledContent(String(localized: "Tags")) {
                    ConnectionTagEditor(tagIds: $coordinator.customization.tagIds)
                }
                LabeledContent(String(localized: "Group")) {
                    ConnectionGroupPicker(selectedGroupId: $coordinator.customization.groupId)
                }
            }

            Section(String(localized: "Query Behavior")) {
                Picker(String(localized: "Safe Mode"), selection: $coordinator.customization.safeModeLevel) {
                    ForEach(SafeModeLevel.allCases) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                .disabled(isEngineReadOnly)
                .help(isEngineReadOnly ? Self.engineReadOnlyHelp : "")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var isEngineReadOnly: Bool {
        PluginManager.shared.isEngineReadOnly(for: coordinator.network.type)
    }

    private static let engineReadOnlyHelp = String(
        localized: "This engine only runs read queries, so the connection is always read-only."
    )
}
