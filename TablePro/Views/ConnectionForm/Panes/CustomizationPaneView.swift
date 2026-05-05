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
                LabeledContent(String(localized: "Tag")) {
                    ConnectionTagEditor(selectedTagId: $coordinator.customization.tagId)
                }
                LabeledContent(String(localized: "Group")) {
                    ConnectionGroupPicker(selectedGroupId: $coordinator.customization.groupId)
                }
            }

            Section(String(localized: "Query Behavior")) {
                let isProUnlocked = LicenseManager.shared.isFeatureAvailable(.safeMode)
                Picker(String(localized: "Safe Mode"), selection: $coordinator.customization.safeModeLevel) {
                    ForEach(SafeModeLevel.allCases) { level in
                        if level.requiresPro && !isProUnlocked {
                            Text("\(level.displayName) (Pro)").tag(level)
                        } else {
                            Text(level.displayName).tag(level)
                        }
                    }
                }
                .onChange(of: coordinator.customization.safeModeLevel) { oldValue, newValue in
                    if newValue.requiresPro && !isProUnlocked {
                        coordinator.customization.safeModeLevel = oldValue
                        coordinator.customization.showSafeModeProAlert = true
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .alert(
            String(localized: "Pro License Required"),
            isPresented: $coordinator.customization.showSafeModeProAlert
        ) {
            Button(String(localized: "Activate License...")) {
                coordinator.customization.showActivationSheet = true
            }
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text(String(localized: "Safe Mode, Safe Mode (Full), and Read Only require a Pro license."))
        }
        .sheet(isPresented: $coordinator.customization.showActivationSheet) {
            LicenseActivationSheet()
        }
    }
}
