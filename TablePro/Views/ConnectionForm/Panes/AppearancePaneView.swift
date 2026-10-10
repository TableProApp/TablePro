//
//  AppearancePaneView.swift
//  TablePro
//

import SwiftUI

/// How this connection is recognised in the connection list and the window chrome.
struct AppearancePaneView: View {
    @ObservedObject var coordinator: ConnectionFormCoordinator

    var body: some View {
        Form {
            Section {
                LabeledContent(String(localized: "Icon")) {
                    SymbolWell(
                        iconName: $coordinator.customization.iconName,
                        subject: .connection(coordinator.network.type),
                        color: coordinator.customization.color,
                        accessibilityIdentifier: "connection-form-icon"
                    )
                }
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
                Text(String(localized: "The icon and color mark this connection in the connection list and its window."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
