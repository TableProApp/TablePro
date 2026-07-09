//
//  SettingsView.swift
//  TablePro
//

import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, appearance, editor, data, sidebar, keyboard, ai, mcp, plugins, account

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .editor: "Editor"
        case .data: "Data & Results"
        case .sidebar: "Sidebar"
        case .keyboard: "Keyboard"
        case .ai: "AI"
        case .mcp: "Integrations"
        case .plugins: "Plugins"
        case .account: "Account"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintbrush"
        case .editor: "doc.text"
        case .data: "tablecells"
        case .sidebar: "sidebar.left"
        case .keyboard: "keyboard"
        case .ai: "sparkles"
        case .mcp: "network"
        case .plugins: "puzzlepiece.extension"
        case .account: "person.crop.circle"
        }
    }
}

struct SettingsView: View {
    @Bindable private var settingsManager = AppSettingsManager.shared
    @Environment(UpdaterBridge.self) var updaterBridge
    @AppStorage(PreferenceKeys.selectedSettingsPane.name) private var selectedPane = SettingsPane.general.rawValue
    private let pluginManager = PluginManager.shared

    private var pluginAttentionCount: Int {
        pluginManager.rejectedPlugins.count + pluginManager.pluginsWithRegistryUpdate.count
    }

    var body: some View {
        TabView(selection: $selectedPane) {
            pane(.general) {
                GeneralSettingsView(
                    settings: $settingsManager.general,
                    tabSettings: $settingsManager.tabs,
                    updaterBridge: updaterBridge,
                    onResetAll: { settingsManager.resetToDefaults() }
                )
            }

            pane(.appearance) {
                AppearanceSettingsView(settings: $settingsManager.appearance)
            }

            pane(.editor) {
                EditorSettingsView(settings: $settingsManager.editor)
            }

            pane(.data) {
                DataResultsSettingsView(
                    dataGrid: $settingsManager.dataGrid,
                    history: $settingsManager.history,
                    editor: $settingsManager.editor
                )
            }

            pane(.sidebar) {
                SidebarSettingsView(general: $settingsManager.general)
            }

            pane(.keyboard) {
                KeyboardSettingsView(settings: $settingsManager.keyboard)
            }

            pane(.ai) {
                AISettingsView(settings: $settingsManager.ai)
            }

            pane(.mcp) {
                MCPSettingsView(settings: $settingsManager.mcp)
            }

            pane(.plugins) {
                PluginsSettingsView()
            }
            .badge(pluginAttentionCount)

            pane(.account) {
                AccountSettingsView()
            }
        }
        .frame(width: 720, height: 500)
    }

    private func pane<Content: View>(_ pane: SettingsPane, @ViewBuilder content: () -> Content) -> some View {
        content()
            .tabItem { Label(pane.title, systemImage: pane.symbol) }
            .tag(pane.rawValue)
    }
}

#Preview {
    SettingsView()
        .environment(UpdaterBridge.shared)
}
