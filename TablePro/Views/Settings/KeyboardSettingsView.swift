//
//  KeyboardSettingsView.swift
//  TablePro
//
//  Settings view for customizing keyboard shortcuts.
//

import AppKit
import SwiftUI

/// Settings view for keyboard shortcut customization
struct KeyboardSettingsView: View {
    @Binding var settings: KeyboardSettings

    @State private var searchText = ""
    @State private var conflictAlert: ConflictAlertState?
    @State private var systemReservedAlert: ShortcutAction?

    var body: some View {
        VStack(spacing: 0) {
            NativeSearchField(
                text: $searchText,
                placeholder: String(localized: "Search shortcuts...")
            )
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 8)

            // Shortcut list
            Form {
                ForEach(ShortcutCategory.allCases) { category in
                    let actions = filteredActions(for: category)
                    if !actions.isEmpty {
                        Section(category.displayName) {
                            ForEach(actions) { action in
                                shortcutRow(for: action)
                            }
                        }
                    }
                }

                Section {
                    HStack {
                        Spacer()
                        Button(String(localized: "Reset to Defaults")) {
                            settings = .default
                        }
                        .disabled(settings.shortcuts.isEmpty)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .alert(
            String(localized: "Shortcut Conflict"),
            isPresented: Binding(
                get: { conflictAlert != nil },
                set: { if !$0 { conflictAlert = nil } }
            )
        ) {
            Button(String(localized: "Cancel"), role: .cancel) {
                conflictAlert = nil
            }
            Button(String(localized: "Reassign")) {
                if let state = conflictAlert {
                    // Clear the conflicting action's shortcut
                    settings.clearShortcut(for: state.conflictingAction)
                    // Assign the new combo to the intended action
                    settings.setShortcut(state.combo, for: state.action)
                }
                conflictAlert = nil
            }
        } message: {
            if let state = conflictAlert {
                Text(
                    "\(state.combo.displayString) is already assigned to \"\(state.conflictingAction.displayName)\". Reassigning will remove it from that action."
                )
            }
        }
        .alert(
            String(localized: "System Reserved Shortcut"),
            isPresented: Binding(
                get: { systemReservedAlert != nil },
                set: { if !$0 { systemReservedAlert = nil } }
            )
        ) {
            Button(String(localized: "OK"), role: .cancel) {
                systemReservedAlert = nil
            }
        } message: {
            Text(String(localized: "This shortcut is reserved by macOS and cannot be assigned."))
        }
    }

    // MARK: - Shortcut Row

    @ViewBuilder
    private func shortcutRow(for action: ShortcutAction) -> some View {
        HStack {
            Text(action.displayName)
                .frame(maxWidth: .infinity, alignment: .leading)

            ShortcutRecorderView(
                combo: Binding(
                    get: { settings.shortcut(for: action) },
                    set: { _ in }
                ),
                onRecord: { newCombo in
                    handleRecord(newCombo, for: action)
                },
                onClear: {
                    settings.clearShortcut(for: action)
                }
            )
            .frame(width: 160, height: 24)
        }
    }

    // MARK: - Helpers

    private func filteredActions(for category: ShortcutCategory) -> [ShortcutAction] {
        let categoryActions = ShortcutAction.allCases.filter { $0.category == category }
        if searchText.isEmpty {
            return categoryActions
        }
        let query = searchText.lowercased()
        return categoryActions.filter { $0.displayName.lowercased().contains(query) }
    }

    private func handleRecord(_ combo: KeyCombo, for action: ShortcutAction) {
        // Check system-reserved shortcuts
        if combo.isSystemReserved {
            systemReservedAlert = action
            return
        }

        // Check for conflicts
        if let conflict = settings.findConflict(for: combo, excluding: action) {
            conflictAlert = ConflictAlertState(
                action: action,
                conflictingAction: conflict,
                combo: combo
            )
            return
        }

        // No conflict — assign directly
        settings.setShortcut(combo, for: action)
    }
}

// MARK: - Conflict Alert State

private struct ConflictAlertState {
    let action: ShortcutAction
    let conflictingAction: ShortcutAction
    let combo: KeyCombo
}
