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
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
