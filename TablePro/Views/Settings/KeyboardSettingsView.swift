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
    @State private var reservedAlert: ReservedAlertState?
    @State private var needsModifierAlert: ShortcutAction?

    private var content: some View {
        VStack(spacing: 0) {
            NativeSearchField(
                text: $searchText,
                placeholder: String(localized: "Search shortcuts...")
            )
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 8)

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
    }

    var body: some View {
        content
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
                    settings.clearShortcut(for: state.conflictingAction)
                    settings.setShortcut(state.combo, for: state.action)
                }
                conflictAlert = nil
            }
        } message: {
            if let state = conflictAlert {
                Text(
                    String(
                        format: String(localized: "%@ is already used by \"%@\" in %@. Reassigning removes it from that action."),
                        state.combo.displayString,
                        state.conflictingAction.displayName,
                        state.conflictingAction.category.displayName
                    )
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
        .alert(
            String(localized: "Reserved Shortcut"),
            isPresented: Binding(
                get: { reservedAlert != nil },
                set: { if !$0 { reservedAlert = nil } }
            )
        ) {
            Button(String(localized: "OK"), role: .cancel) {
                reservedAlert = nil
            }
        } message: {
            if let state = reservedAlert {
                Text(
                    String(
                        format: String(localized: "This shortcut is reserved for \"%@\" and cannot be assigned."),
                        state.name
                    )
                )
            }
        }
        .alert(
            String(localized: "Modifier Key Required"),
            isPresented: Binding(
                get: { needsModifierAlert != nil },
                set: { if !$0 { needsModifierAlert = nil } }
            )
        ) {
            Button(String(localized: "OK"), role: .cancel) {
                needsModifierAlert = nil
            }
        } message: {
            Text(String(localized: "This action needs a modifier key like ⌘ or ⌥. A plain key won't reach the menu reliably."))
        }
        .onAppear {
            SystemHotkeyChecker.shared.reload()
        }
    }

    // MARK: - Shortcut Row

    @ViewBuilder
    private func shortcutRow(for action: ShortcutAction) -> some View {
        HStack(spacing: 8) {
            Text(action.displayName)
                .frame(maxWidth: .infinity, alignment: .leading)

            if settings.isCustomized(action) {
                Button {
                    settings.resetToDefault(for: action)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help(String(localized: "Reset to default"))
                .accessibilityLabel(String(localized: "Reset to default"))
            }

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

    private func handleRecord(_ key: BoundKey, for action: ShortcutAction) {
        if !key.hasModifier, !action.allowsBareKey, !key.isFunctionKey {
            needsModifierAlert = action
            return
        }

        switch ShortcutConflictResolver.resolve(key, for: action, in: settings) {
        case .none:
            settings.setShortcut(key, for: action)
        case .systemReserved:
            systemReservedAlert = action
        case .reserved(let name):
            reservedAlert = ReservedAlertState(action: action, name: name)
        case .otherAction(let other):
            conflictAlert = ConflictAlertState(action: action, conflictingAction: other, combo: key)
        }
    }
}

// MARK: - Alert State

private struct ConflictAlertState {
    let action: ShortcutAction
    let conflictingAction: ShortcutAction
    let combo: BoundKey
}

private struct ReservedAlertState {
    let action: ShortcutAction
    let name: String
}
