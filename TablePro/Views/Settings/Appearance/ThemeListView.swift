import AppKit
import os
import SwiftUI
import UniformTypeIdentifiers

/// Every action here acts on the theme the slot has selected. Acting on the active theme instead
/// let a delete in the dark slot write the light theme's id into it, so at dusk the editor turned
/// white inside dark chrome.
internal struct ThemeListView: View {
    @Binding internal var selectedThemeId: String
    internal var slotAppearance: ThemeAppearance = .light

    @State private var showDeleteConfirmation = false
    @State private var errorMessage: String?
    @State private var showError = false

    private static let logger = Logger(subsystem: "com.TablePro", category: "ThemeListView")

    private var catalog: ThemeCatalog { ThemeCatalog.shared }

    private var builtInThemes: [ThemeDefinition] {
        eligible(catalog.themes.filter(\.isBuiltIn))
    }

    private var registryThemes: [ThemeDefinition] {
        eligible(catalog.themes.filter(\.isRegistry))
    }

    private var customThemes: [ThemeDefinition] {
        eligible(catalog.themes.filter(\.isEditable))
    }

    private var selectedTheme: ThemeDefinition? {
        catalog.theme(id: selectedThemeId)
    }

    private var fallbackThemeId: String {
        BuiltInThemes.defaultId(for: slotAppearance)
    }

    private func eligible(_ themes: [ThemeDefinition]) -> [ThemeDefinition] {
        ThemeSlotValidation.eligibleThemes(themes, slot: slotAppearance, keeping: selectedThemeId)
    }

    internal var body: some View {
        VStack(spacing: 0) {
            List(selection: $selectedThemeId) {
                Section("Built-in") {
                    ForEach(builtInThemes) { theme in
                        ThemeListRowView(theme: theme).tag(theme.id)
                    }
                }

                if !registryThemes.isEmpty {
                    Section("Registry") {
                        ForEach(registryThemes) { theme in
                            ThemeListRowView(theme: theme).tag(theme.id)
                        }
                    }
                }

                if !customThemes.isEmpty {
                    Section("Custom") {
                        ForEach(customThemes) { theme in
                            ThemeListRowView(theme: theme).tag(theme.id)
                        }
                    }
                }

                if !catalog.rejected.isEmpty {
                    Section("Not Loaded") {
                        ForEach(catalog.rejected, id: \.path) { record in
                            rejectedRow(record)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            Divider()

            toolbar
        }
        .alert(String(localized: "Delete Theme"), isPresented: $showDeleteConfirmation) {
            Button(String(localized: "Delete"), role: .destructive) { deleteSelectedTheme() }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(
                format: String(localized: "Are you sure you want to delete \"%@\"?"),
                selectedTheme?.name ?? ""
            ))
        }
        .alert(String(localized: "Error"), isPresented: $showError) {
            Button(String(localized: "OK")) {}
        } message: {
            if let errorMessage {
                Text(errorMessage)
            }
        }
    }

    /// A file the loader refused is shown with its reason rather than dropped in silence, which is
    /// what the previous loader did for a malformed theme.
    private func rejectedRow(_ record: RejectedThemeRecord) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(record.fileName)
                .font(.callout)
                .lineLimit(1)

            Text(record.reason)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
        .help(Text(record.reason))
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            Menu {
                Button(String(localized: "Duplicate Selected")) { duplicateSelectedTheme() }
                Divider()
                Button(String(localized: "Import…")) { importTheme() }
            } label: {
                Image(systemName: "plus").frame(width: 24, height: 24)
            }
            .menuIndicator(.hidden)
            .buttonStyle(.borderless)
            .frame(width: 28)
            .help(Text("Add Theme"))
            .accessibilityLabel(Text("Add Theme"))

            Button {
                showDeleteConfirmation = true
            } label: {
                Image(systemName: "minus").frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .disabled(selectedTheme?.isEditable != true)
            .help(Text("Delete Theme"))
            .accessibilityLabel(Text("Delete Theme"))

            Menu {
                Button(String(localized: "Duplicate")) { duplicateSelectedTheme() }
                Button(String(localized: "Export…")) { exportSelectedTheme() }
                if selectedTheme?.isRegistry == true {
                    Divider()
                    Button(String(localized: "Uninstall"), role: .destructive) { uninstallRegistryTheme() }
                }
            } label: {
                Image(systemName: "gearshape").frame(width: 24, height: 24)
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

    // MARK: - Actions

    private func duplicateSelectedTheme() {
        guard let theme = selectedTheme else { return }
        var copy = theme
        copy.id = ThemeIdentifier.generated()
        copy.name = String(format: String(localized: "%@ (Copy)"), theme.name)

        perform { try catalog.save(copy) } then: { selectedThemeId = copy.id }
    }

    private func deleteSelectedTheme() {
        guard let theme = selectedTheme, theme.isEditable else { return }
        perform { try catalog.delete(id: theme.id) } then: { selectedThemeId = fallbackThemeId }
    }

    private func uninstallRegistryTheme() {
        guard let theme = selectedTheme, theme.isRegistry else { return }
        guard let entry = catalog.loadRegistryMeta().installed.first(where: { $0.id == theme.id }) else { return }

        perform {
            try ThemeRegistryInstaller.shared.uninstall(registryPluginId: entry.registryPluginId)
        } then: {
            selectedThemeId = fallbackThemeId
        }
    }

    private func exportSelectedTheme() {
        guard let theme = selectedTheme, let window = AlertHelper.resolveWindow(nil) else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = theme.name + ".json"
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try catalog.exportTheme(theme, to: url)
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
            perform {
                let imported = try catalog.importTheme(from: url)
                guard imported.appearance == slotAppearance else { return }
                selectedThemeId = imported.id
            }
        }
    }

    private func perform(_ work: () throws -> Void, then completion: () -> Void = {}) {
        do {
            try work()
            completion()
        } catch {
            Self.logger.error("Theme action failed: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}
