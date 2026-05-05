//
//  AppearanceSettingsView.swift
//  TablePro
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AppearanceSettingsView: View {
    @Binding var settings: AppearanceSettings

    private var engine: ThemeEngine { ThemeEngine.shared }

    @State private var editingTheme: EditingTheme?
    @State private var pendingDeleteThemeId: String?

    private struct EditingTheme: Identifiable {
        let id: String
    }
    @State private var showDeleteConfirmation = false
    @State private var errorMessage: String?
    @State private var showError = false

    private var effectiveThemeIdBinding: Binding<String> {
        Binding(
            get: {
                ThemeEngine.shared.effectiveAppearance == .dark
                    ? settings.preferredDarkThemeId
                    : settings.preferredLightThemeId
            },
            set: { newId in
                guard let theme = ThemeEngine.shared.availableThemes
                    .first(where: { $0.id == newId }) else { return }

                var updated = settings
                switch theme.appearance {
                case .dark:
                    updated.preferredDarkThemeId = newId
                    updated.appearanceMode = .dark
                case .light:
                    updated.preferredLightThemeId = newId
                    updated.appearanceMode = .light
                case .auto:
                    updated.appearanceMode = .auto
                    if ThemeEngine.shared.effectiveAppearance == .dark {
                        updated.preferredDarkThemeId = newId
                    } else {
                        updated.preferredLightThemeId = newId
                    }
                }
                settings = updated
            }
        )
    }

    var body: some View {
        Form {
            appearanceSection
            themesSection(builtInThemes, title: String(localized: "Built-in"), showAddMenu: true)
            if !registryThemes.isEmpty {
                themesSection(registryThemes, title: String(localized: "Registry"), showAddMenu: false)
            }
            if !customThemes.isEmpty {
                themesSection(customThemes, title: String(localized: "Custom"), showAddMenu: false)
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editingTheme) { item in
            themeEditorSheet(themeId: item.id)
        }
        .alert(String(localized: "Delete Theme"), isPresented: $showDeleteConfirmation) {
            Button(String(localized: "Delete"), role: .destructive) {
                if let id = pendingDeleteThemeId {
                    deleteTheme(id: id)
                }
                pendingDeleteThemeId = nil
            }
            Button(String(localized: "Cancel"), role: .cancel) {
                pendingDeleteThemeId = nil
            }
        } message: {
            if let id = pendingDeleteThemeId,
               let name = engine.availableThemes.first(where: { $0.id == id })?.name {
                Text(String(format: String(localized: "Are you sure you want to delete \"%@\"?"), name))
            }
        }
        .alert(String(localized: "Error"), isPresented: $showError) {
            Button(String(localized: "OK")) {}
        } message: {
            if let errorMessage {
                Text(errorMessage)
            }
        }
    }

    // MARK: - Sections

    private var appearanceSection: some View {
        Section {
            Picker(String(localized: "Mode"), selection: $settings.appearanceMode) {
                ForEach(AppAppearanceMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    @ViewBuilder
    private func themesSection(_ themes: [ThemeDefinition], title: String, showAddMenu: Bool) -> some View {
        Section {
            ForEach(themes) { theme in
                Button {
                    effectiveThemeIdBinding.wrappedValue = theme.id
                    editingTheme = EditingTheme(id: theme.id)
                } label: {
                    ThemeListRowView(theme: theme)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .contextMenu {
                    Button(String(localized: "Apply")) {
                        effectiveThemeIdBinding.wrappedValue = theme.id
                    }
                    Button(String(localized: "Edit…")) {
                        editingTheme = EditingTheme(id: theme.id)
                    }
                    Button(String(localized: "Duplicate")) {
                        duplicate(theme: theme)
                    }
                    Button(String(localized: "Export…")) {
                        export(theme: theme)
                    }
                    if theme.isEditable {
                        Divider()
                        Button(String(localized: "Delete"), role: .destructive) {
                            pendingDeleteThemeId = theme.id
                            showDeleteConfirmation = true
                        }
                    }
                    if theme.isRegistry {
                        Divider()
                        Button(String(localized: "Uninstall"), role: .destructive) {
                            uninstallRegistryTheme(theme: theme)
                        }
                    }
                }
            }
        } header: {
            HStack {
                Text(title)
                Spacer()
                if showAddMenu {
                    addMenu
                }
            }
        }
    }

    private var addMenu: some View {
        Menu {
            Button(String(localized: "New Theme")) {
                duplicate(theme: engine.activeTheme)
            }
            Button(String(localized: "Import…")) {
                importTheme()
            }
        } label: {
            Label(String(localized: "Add Theme"), systemImage: "plus")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: - Theme editor sheet

    @ViewBuilder
    private func themeEditorSheet(themeId: String) -> some View {
        if engine.availableThemes.contains(where: { $0.id == themeId }) {
            NavigationStack {
                ThemeEditorView(selectedThemeId: .constant(themeId))
                    .frame(minWidth: 540, minHeight: 480)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(String(localized: "Done")) {
                                editingTheme = nil
                            }
                        }
                    }
            }
            .frame(width: 600, height: 540)
        }
    }

    // MARK: - Theme groups

    private var builtInThemes: [ThemeDefinition] {
        engine.availableThemes.filter(\.isBuiltIn)
    }

    private var registryThemes: [ThemeDefinition] {
        engine.registryThemes
    }

    private var customThemes: [ThemeDefinition] {
        engine.availableThemes.filter(\.isEditable)
    }

    // MARK: - Actions

    private func duplicate(theme: ThemeDefinition) {
        let copy = engine.duplicateTheme(theme, newName: theme.name + " (Copy)")
        do {
            try engine.saveUserTheme(copy)
            effectiveThemeIdBinding.wrappedValue = copy.id
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func deleteTheme(id: String) {
        do {
            try engine.deleteUserTheme(id: id)
            effectiveThemeIdBinding.wrappedValue = engine.activeTheme.id
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func uninstallRegistryTheme(theme: ThemeDefinition) {
        let meta = ThemeStorage.loadRegistryMeta()
        guard let entry = meta.installed.first(where: { $0.id == theme.id }) else { return }
        do {
            try engine.uninstallRegistryTheme(registryPluginId: entry.registryPluginId)
            effectiveThemeIdBinding.wrappedValue = engine.activeTheme.id
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func export(theme: ThemeDefinition) {
        guard let window = NSApp.keyWindow else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = theme.name + ".json"
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            try? engine.exportTheme(theme, to: url)
        }
    }

    private func importTheme() {
        guard let window = NSApp.keyWindow else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let imported = try self.engine.importTheme(from: url)
                self.effectiveThemeIdBinding.wrappedValue = imported.id
            } catch {
                self.errorMessage = error.localizedDescription
                self.showError = true
            }
        }
    }
}

#Preview {
    AppearanceSettingsView(settings: .constant(.default))
        .frame(width: 720, height: 500)
}
