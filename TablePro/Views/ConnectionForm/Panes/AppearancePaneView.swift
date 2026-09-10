//
//  AppearancePaneView.swift
//  TablePro
//

import SwiftUI

/// How this connection is recognised in the connection list and the window chrome.
struct AppearancePaneView: View {
    @Bindable var coordinator: ConnectionFormCoordinator

    var body: some View {
        Form {
            Section {
                LabeledContent(String(localized: "Color")) {
                    ConnectionColorPicker(selectedColor: $coordinator.customization.color)
                }
                LabeledContent(String(localized: "Tags")) {
                    ConnectionTagEditor(tagIds: $coordinator.customization.tagIds)
                }
                LabeledContent(String(localized: "Group")) {
                    ConnectionGroupPicker(selectedGroupId: $coordinator.customization.groupId)
                }
            } footer: {
                Text(String(localized: "The color marks this connection in the connection list and its window."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
