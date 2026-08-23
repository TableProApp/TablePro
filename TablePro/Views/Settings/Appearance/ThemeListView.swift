import AppKit
import SwiftUI
import UniformTypeIdentifiers

internal struct ThemeListView: View {
    @Binding var selectedThemeId: String
    internal var slotAppearance: ThemeAppearance = .light

    private var engine: ThemeEngine { ThemeEngine.shared }

    @State private var showDeleteConfirmation = false
    @State private var errorMessage: String?
    @State private var showError = false

    private var builtInThemes: [ThemeDefinition] {
        ThemeSlotValidation.eligibleThemes(
            engine.availableThemes.filter(\.isBuiltIn),
            slot: slotAppearance,
            keeping: selectedThemeId
        )
    }

    private var registryThemes: [ThemeDefinition] {
        ThemeSlotValidation.eligibleThemes(
            engine.registryThemes,
            slot: slotAppearance,
            keeping: selectedThemeId
        )
    }

    private var customThemes: [ThemeDefinition] {
        ThemeSlotValidation.eligibleThemes(
            engine.availableThemes.filter(\.isEditable),
            slot: slotAppearance,
            keeping: selectedThemeId
        )
    }

    private var selectedTheme: ThemeDefinition? {
        engine.availableThemes.first { $0.id == selectedThemeId }
    }

    private var isDeleteDisabled: Bool {
        guard let theme = selectedTheme else { return true }
        return !theme.isEditable
    }

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selectedThemeId) {
                Section("Built-in") {
                    ForEach(builtInThemes) { theme in
                        ThemeListRowView(theme: theme)
                            .tag(theme.id)
                    }
                }

                if !registryThemes.isEmpty {
                    Section("Registry") {
                        ForEach(registryThemes) { theme in
                            ThemeListRowView(theme: theme)
                                .tag(theme.id)
                        }
                    }
                }

                if !customThemes.isEmpty {
                    Section("Custom") {
                        ForEach(customThemes) { theme in
                            ThemeListRowView(theme: theme)
                                .tag(theme.id)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            Divider()

            HStack(spacing: 4) {
                Menu {
                    Button(String(localized: "New Theme")) {
                        duplicateActiveTheme()
                    }
                    Divider()
                    Button(String(localized: "Import…")) {
                        importTheme()
                    }
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 24, height: 24)
                }
                .menuIndicator(.hidden)
                .buttonStyle(.borderless)
                .frame(width: 28)
                .help(Text("Add Theme"))
                .accessibilityLabel(Text("Add Theme"))

                Button {
                    showDeleteConfirmation = true
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .disabled(isDeleteDisabled)
                .help(Text("Delete Theme"))
                .accessibilityLabel(Text("Delete Theme"))

                Menu {
                    Button(String(localized: "Duplicate")) {
                        duplicateActiveTheme()
                    }
                    Button(String(localized: "Export…")) {
                        exportActiveTheme()
                    }
                    if selectedTheme?.isRegistry == true {
                        Divider()
                        Button(String(localized: "Uninstall"), role: .destructive) {
                            uninstallRegistryTheme()
                        }
                    }
                } label: {
                    Image(systemName: "gearshape")
                        .frame(width: 24, height: 24)
                }
                .menuIndicator(.hidden)
                .buttonStyle(.borderless)
                .frame(width: 28)
                .help(Text("Theme Actions"))
                .accessibilityLabel(Text("Theme Actions"))

                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .alert(String(localized: "Delete Theme"), isPresented: $showDeleteConfirmation) {
            Button(String(localized: "Delete"), role: .destructive) {
                deleteSelectedTheme()
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            let name = engine.availableThemes.first(where: { $0.id == selectedThemeId })?.name ?? ""
            Text(String(format: String(localized: "Are you sure you want to delete \"%@\"?"), name))
        }
        .alert(String(localized: "Error"), isPresented: $showError) {
            Button(String(localized: "OK")) {}
        } message: {
            if let errorMessage {
                Text(errorMessage)
            }
        }
    }

    // MARK: - Actions

    private func duplicateActiveTheme() {
        let theme = engine.activeTheme
        let copy = engine.duplicateTheme(theme, newName: theme.name + " (Copy)")
        do {
            try engine.saveUserTheme(copy)
            selectedThemeId = copy.id
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func deleteSelectedTheme() {
        do {
            try engine.deleteUserTheme(id: selectedThemeId)
            selectedThemeId = engine.activeTheme.id
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func uninstallRegistryTheme() {
        guard let theme = selectedTheme, theme.isRegistry else { return }
        let meta = ThemeStorage.loadRegistryMeta()
        guard let entry = meta.installed.first(where: { $0.id == theme.id }) else { return }
        do {
            try engine.uninstallRegistryTheme(registryPluginId: entry.registryPluginId)
            selectedThemeId = engine.activeTheme.id
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func exportActiveTheme() {
        guard let window = AlertHelper.resolveWindow(nil) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = engine.activeTheme.name + ".json"
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try engine.exportTheme(engine.activeTheme, to: url)
            } catch {
                AlertHelper.showErrorSheet(
                    title: String(localized: "Could not export the theme"),
                    message: error.localizedDescription,
                    window: window
                )
            }
        }
    }

    private func importTheme() {
        guard let window = AlertHelper.resolveWindow(nil) else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let imported = try self.engine.importTheme(from: url)
                self.selectedThemeId = imported.id
            } catch {
                self.errorMessage = error.localizedDescription
                self.showError = true
            }
        }
    }
}
