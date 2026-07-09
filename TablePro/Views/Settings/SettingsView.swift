//
//  SettingsView.swift
//  TablePro
//

import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, appearance, editor, data, sidebar, savedCustomizations, keyboard, ai, mcp, plugins, account

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .appearance: String(localized: "Appearance")
        case .editor: String(localized: "Editor")
        case .data: String(localized: "Data & Results")
        case .sidebar: String(localized: "Sidebar")
        case .savedCustomizations: String(localized: "Saved Customizations")
        case .keyboard: String(localized: "Keyboard")
        case .ai: String(localized: "AI")
        case .mcp: String(localized: "Integrations")
        case .plugins: String(localized: "Plugins")
        case .account: String(localized: "Account")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintbrush"
        case .editor: "doc.text"
        case .data: "tablecells"
        case .sidebar: "sidebar.left"
        case .savedCustomizations: "slider.horizontal.3"
        case .keyboard: "keyboard"
        case .ai: "sparkles"
        case .mcp: "network"
        case .plugins: "puzzlepiece.extension"
        case .account: "person.crop.circle"
        }
    }

    var keywords: [String] {
        switch self {
        case .general: ["language", "startup", "updates", "sparkle", "privacy", "analytics", "query timeout", "tabs", "preview"]
        case .appearance: ["theme", "dark", "light", "color", "font", "syntax"]
        case .editor: ["sql", "vim", "line numbers", "word wrap", "tab width", "uppercase", "parameters"]
        case .data: ["grid", "pagination", "row height", "date", "null", "json viewer", "history", "page size", "sort", "result cap"]
        case .sidebar: ["recent tables", "layout", "tree", "list", "object comments", "navigator"]
        case .savedCustomizations: ["saved", "customizations", "column layout", "widths", "reset", "per table"]
        case .keyboard: ["shortcuts", "keys", "bindings"]
        case .ai: ["assistant", "copilot", "model", "provider", "chat", "openai", "anthropic"]
        case .mcp: ["mcp", "server", "token", "integration"]
        case .plugins: ["drivers", "database", "registry", "install"]
        case .account: ["license", "sync", "icloud", "team", "linked folders", "subscription"]
        }
    }

    func matches(_ query: String) -> Bool {
        let needle = query.lowercased()
        if title.lowercased().contains(needle) { return true }
        return keywords.contains { $0.contains(needle) }
    }
}

struct SettingsView: View {
    @Bindable private var settingsManager = AppSettingsManager.shared
    @Environment(UpdaterBridge.self) var updaterBridge
    @AppStorage(PreferenceKeys.selectedSettingsPane.name) private var selectedRaw = SettingsPane.general.rawValue
    @State private var searchText = ""
    private let pluginManager = PluginManager.shared

    private var pluginAttentionCount: Int {
        pluginManager.rejectedPlugins.count + pluginManager.pluginsWithRegistryUpdate.count
    }

    private var visiblePanes: [SettingsPane] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return SettingsPane.allCases }
        return SettingsPane.allCases.filter { $0.matches(query) }
    }

    private var selection: Binding<SettingsPane?> {
        Binding(
            get: { SettingsPane(rawValue: selectedRaw) ?? .general },
            set: { newValue in
                if let newValue { selectedRaw = newValue.rawValue }
            }
        )
    }

    var body: some View {
        NavigationSplitView {
            List(visiblePanes, selection: selection) { pane in
                Label(pane.title, systemImage: pane.symbol)
                    .badge(pane == .plugins && pluginAttentionCount > 0 ? Text(pluginAttentionCount.formatted()) : nil)
                    .tag(pane)
            }
            .navigationTitle("Settings")
            .searchable(text: $searchText, placement: .sidebar, prompt: Text("Search settings"))
            .navigationSplitViewColumnWidth(min: 200, ideal: 216, max: 260)
        } detail: {
            detail(for: SettingsPane(rawValue: selectedRaw) ?? .general)
                .frame(minWidth: 480, minHeight: 460)
        }
        .frame(minWidth: 740, minHeight: 520)
    }

    @ViewBuilder
    private func detail(for pane: SettingsPane) -> some View {
        switch pane {
        case .general:
            GeneralSettingsView(
                settings: $settingsManager.general,
                tabSettings: $settingsManager.tabs,
                updaterBridge: updaterBridge,
                onResetAll: { settingsManager.resetToDefaults() }
            )
        case .appearance:
            AppearanceSettingsView(settings: $settingsManager.appearance)
        case .editor:
            EditorSettingsView(settings: $settingsManager.editor)
        case .data:
            DataResultsSettingsView(
                dataGrid: $settingsManager.dataGrid,
                history: $settingsManager.history,
                editor: $settingsManager.editor
            )
        case .sidebar:
            SidebarSettingsView(general: $settingsManager.general)
        case .savedCustomizations:
            SavedCustomizationsSettingsView()
        case .keyboard:
            KeyboardSettingsView(settings: $settingsManager.keyboard)
        case .ai:
            AISettingsView(settings: $settingsManager.ai)
        case .mcp:
            MCPSettingsView(settings: $settingsManager.mcp)
        case .plugins:
            PluginsSettingsView()
        case .account:
            AccountSettingsView()
        }
    }
}

#Preview {
    SettingsView()
        .environment(UpdaterBridge.shared)
}
