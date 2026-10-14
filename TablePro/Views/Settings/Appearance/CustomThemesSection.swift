import AppKit
import os
import SwiftUI
import UniformTypeIdentifiers

/// The user's theme files, with the add and remove pair and the action pull-down macOS puts under
/// a list. Every action names the theme it acts on: a context menu acts on the row under the
/// pointer, which is not always the selected one.
internal struct CustomThemesSection: View {
    @Binding internal var settings: AppearanceSettings

    @ObservedObject private var catalog = ThemeCatalog.shared

    @State private var selection: CustomThemeItem?
    @State private var editing: ThemeDefinition?
    @State private var renaming: ThemeDefinition?
    @State private var renameText = ""
    @State private var deleting: ThemeDefinition?
    @State private var failure: Failure?

    private struct Failure {
        let title: String
        let message: String
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "CustomThemesSection")
    private static let rowHeight: CGFloat = 34
    private static let barHeight: CGFloat = 28

    private var model: CustomThemeListModel {
        CustomThemeListModel(themes: catalog.themes, rejected: catalog.rejected)
    }

    private var selectedTheme: ThemeDefinition? {
        model.theme(for: selection)
    }

    internal var body: some View {
        Section {
            list
                .sheet(item: $editing) { theme in
                    ThemeEditorSheet(theme: theme, takenNames: takenNames(excluding: theme.id), save: saveEdited)
                }
                .alert(failure?.title ?? "", isPresented: isPresented($failure), presenting: failure) { _ in
                    Button(String(localized: "OK")) {}
                } message: { failure in
                    Text(failure.message)
                }
                .onAppear { reload() }
                // Picks up a file fixed or dropped into the Themes folder while TablePro was in the background.
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    guard editing == nil else { return }
                    reload()
                }
        } header: {
            Text("Custom Themes")
        }
    }

    // MARK: - List

    private var list: some View {
        List(selection: $selection) {
            ForEach(model.themes) { theme in
                themeRow(theme)
                    .tag(CustomThemeItem.theme(theme.id))
            }

            if !model.notLoaded.isEmpty {
                Section(String(localized: "Not Loaded")) {
                    ForEach(model.notLoaded) { record in
                        notLoadedRow(record)
                            .tag(CustomThemeItem.notLoaded(path: record.path))
                    }
                }
            }
        }
        .listStyle(.bordered(alternatesRowBackgrounds: false))
        .frame(height: listHeight)
        .contextMenu(forSelectionType: CustomThemeItem.self) { items in
            rowMenu(for: items.first)
        } primaryAction: { items in
            guard let theme = model.theme(for: items.first) else { return }
            editing = theme
        }
        .onDeleteCommand { requestDelete(selectedTheme) }
        .overlay {
            if model.isEmpty {
                Text("No Custom Themes")
                    .foregroundStyle(.secondary)
                    .padding(.bottom, Self.barHeight)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            footer
        }
        .alert(String(localized: "Delete Theme"), isPresented: isPresented($deleting), presenting: deleting) { theme in
            Button(String(localized: "Delete"), role: .destructive) { delete(theme) }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: { theme in
            Text(String(format: String(localized: "Are you sure you want to delete \"%@\"?"), theme.name))
        }
    }

    private var listHeight: CGFloat {
        let rows = CGFloat(max(model.themes.count + model.notLoaded.count, 3))
        let sectionHeader: CGFloat = model.notLoaded.isEmpty ? 0 : 28
        return min(rows * Self.rowHeight + sectionHeader + Self.barHeight + 8, 260)
    }

    private func themeRow(_ theme: ThemeDefinition) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(theme.name)
                .lineLimit(1)
            Text(CustomThemeListModel.appearanceLabel(theme.appearance))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func notLoadedRow(_ record: RejectedThemeRecord) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(record.fileName)
                .lineLimit(1)
            Text(record.reason)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
        .help(record.reason)
    }

    /// A contextual menu leaves out what does not apply; the pull-down below dims it instead.
    @ViewBuilder
    private func rowMenu(for item: CustomThemeItem?) -> some View {
        if let theme = model.theme(for: item) {
            Button(String(localized: "Edit…")) { editing = theme }
            Button(String(localized: "Rename…")) { beginRename(theme) }
            Button(String(localized: "Duplicate")) { duplicate(theme) }
            Button(String(localized: "Export…")) { export(theme) }
            Button(String(localized: "Show in Finder")) { reveal(theme) }
            Divider()
            Button(String(localized: "Delete…")) { requestDelete(theme) }
        } else if let record = model.record(for: item) {
            Button(String(localized: "Show in Finder")) { reveal(URL(fileURLWithPath: record.path)) }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 0) {
                ControlGroup {
                    addMenu

                    Button {
                        requestDelete(selectedTheme)
                    } label: {
                        Label(String(localized: "Delete Theme"), systemImage: "minus")
                            .labelStyle(.iconOnly)
                    }
                    .help(String(localized: "Delete Theme"))
                    .accessibilityLabel(String(localized: "Delete Theme"))
                    .accessibilityIdentifier("appearance-theme-remove")
                    .disabled(selectedTheme == nil)

                    actionsMenu
                }
                .controlGroupStyle(.navigation)
                .controlSize(.small)
                .fixedSize()

                Spacer()
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
        }
        .background(.bar)
        .alert(String(localized: "Rename Theme"), isPresented: isPresented($renaming), presenting: renaming) { theme in
            TextField(String(localized: "Name"), text: $renameText)
                .accessibilityIdentifier("appearance-theme-rename-field")
            Button(String(localized: "Rename")) { rename(theme) }
            Button(String(localized: "Cancel"), role: .cancel) {}
        }
    }

    /// An icon-only `Menu` is named only through `.contain` plus a label on the menu itself; a
    /// label inside its label closure leaves VoiceOver reading "More", or nothing on CI.
    private var addMenu: some View {
        Menu {
            Menu(String(localized: "New Theme Based On")) {
                ForEach(catalog.themes.filter(\.isBuiltIn)) { theme in
                    Button(theme.name) { duplicate(theme) }
                }
                if !model.themes.isEmpty {
                    Divider()
                    ForEach(model.themes) { theme in
                        Button(theme.name) { duplicate(theme) }
                    }
                }
            }
            Divider()
            Button(String(localized: "Import…"), action: importTheme)
        } label: {
            Label(String(localized: "Add Theme"), systemImage: "plus")
                .labelStyle(.iconOnly)
        }
        .menuIndicator(.hidden)
        .help(String(localized: "Add Theme"))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Add Theme"))
        .accessibilityIdentifier("appearance-theme-add")
    }

    private var actionsMenu: some View {
        Menu {
            Button(String(localized: "Edit…")) { editing = selectedTheme }
                .disabled(selectedTheme == nil)
            Button(String(localized: "Rename…")) {
                if let theme = selectedTheme { beginRename(theme) }
            }
            .disabled(selectedTheme == nil)
            Button(String(localized: "Duplicate")) {
                if let theme = selectedTheme { duplicate(theme) }
            }
            .disabled(selectedTheme == nil)
            Button(String(localized: "Export…")) {
                if let theme = selectedTheme { export(theme) }
            }
            .disabled(selectedTheme == nil)
            Divider()
            Button(String(localized: "Show in Finder"), action: revealSelection)
        } label: {
            Label(String(localized: "Theme Actions"), systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
        }
        .menuIndicator(.hidden)
        .help(String(localized: "Theme Actions"))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Theme Actions"))
        .accessibilityIdentifier("appearance-theme-actions")
    }

    // MARK: - Actions

    private func duplicate(_ theme: ThemeDefinition) {
        perform(String(localized: "Could not create the theme")) {
            let copy = try catalog.duplicate(theme)
            selection = .theme(copy.id)
        }
    }

    private func beginRename(_ theme: ThemeDefinition) {
        renameText = theme.name
        renaming = theme
    }

    private func rename(_ theme: ThemeDefinition) {
        let taken = takenNames(excluding: theme.id)
        guard let name = ThemeNaming.renamed(renameText, current: theme.name, takenNames: taken) else { return }
        perform(String(localized: "Could not rename the theme")) {
            try catalog.rename(id: theme.id, to: name)
            reapply()
        }
    }

    private func requestDelete(_ theme: ThemeDefinition?) {
        guard let theme else { return }
        deleting = theme
    }

    private func delete(_ theme: ThemeDefinition) {
        perform(String(localized: "Could not delete the theme")) {
            do {
                try catalog.delete(id: theme.id)
            } catch {
                reapply()
                throw error
            }
            if selection == .theme(theme.id) {
                selection = nil
            }
            let released = settings.releasing(themeId: theme.id)
            if released != settings {
                settings = released
            } else {
                reapply()
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
            perform(String(localized: "Could not import the theme")) {
                let imported = try catalog.importTheme(from: url)
                selection = .theme(imported.id)
                // A saved choice that was missing on this Mac may be the theme just imported.
                reapply()
            }
        }
    }

    private func export(_ theme: ThemeDefinition) {
        guard let window = AlertHelper.resolveWindow(nil) else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = theme.name + ".json"
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            perform(String(localized: "Could not export the theme")) {
                try catalog.exportTheme(theme, to: url)
            }
        }
    }

    private func revealSelection() {
        if let theme = selectedTheme {
            reveal(theme)
        } else if let record = model.record(for: selection) {
            reveal(URL(fileURLWithPath: record.path))
        } else {
            NSWorkspace.shared.open(catalog.themesDirectory)
        }
    }

    private func reveal(_ theme: ThemeDefinition) {
        guard let url = catalog.fileURL(for: theme.id) else {
            NSWorkspace.shared.open(catalog.themesDirectory)
            return
        }
        reveal(url)
    }

    private func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Catalog

    /// A conflict with the file on disk reloads the catalog and throws; the engine still takes the reloaded theme.
    private func saveEdited(_ theme: ThemeDefinition) throws {
        defer { reapply() }
        try catalog.save(theme)
    }

    private func reload() {
        let before = catalog.themes
        catalog.reloadSynchronously()
        guard catalog.themes != before else { return }
        reapply()
    }

    private func reapply() {
        ThemeEngine.shared.reapply(
            lightThemeId: settings.preferredLightThemeId,
            darkThemeId: settings.preferredDarkThemeId
        )
    }

    private func takenNames(excluding id: String) -> Set<String> {
        Set(catalog.themes.filter { $0.id != id }.map(\.name))
    }

    private func perform(_ title: String, _ work: () throws -> Void) {
        do {
            try work()
        } catch {
            Self.logger.error("Theme action failed: \(error.publicLogShape, privacy: .public)")
            failure = Failure(title: title, message: error.localizedDescription)
        }
    }

    private func isPresented<Value>(_ value: Binding<Value?>) -> Binding<Bool> {
        Binding(
            get: { value.wrappedValue != nil },
            set: { if !$0 { value.wrappedValue = nil } }
        )
    }
}
