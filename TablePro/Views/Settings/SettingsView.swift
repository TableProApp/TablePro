//
//  SettingsView.swift
//  TablePro
//

import SwiftUI

enum SettingsTab: String {
    case general, appearance, editor, data, sidebar, keyboard, ai, mcp, plugins, account
}

struct SettingsView: View {
    @Bindable private var settingsManager = AppSettingsManager.shared
    @Environment(UpdaterBridge.self) var updaterBridge
    @AppStorage("selectedSettingsTab") private var selectedTab: String = SettingsTab.general.rawValue
    private let pluginManager = PluginManager.shared

    private var pluginAttentionCount: Int {
        pluginManager.rejectedPlugins.count + pluginManager.pluginsWithRegistryUpdate.count
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsView(
                settings: $settingsManager.general,
                tabSettings: $settingsManager.tabs,
                updaterBridge: updaterBridge,
                onResetAll: { settingsManager.resetToDefaults() }
            )
            .tabItem { Label("General", systemImage: "gearshape") }
            .tag(SettingsTab.general.rawValue)

            AppearanceSettingsView(settings: $settingsManager.appearance)
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
                .tag(SettingsTab.appearance.rawValue)

            EditorSettingsView(settings: $settingsManager.editor)
                .tabItem { Label("Editor", systemImage: "doc.text") }
                .tag(SettingsTab.editor.rawValue)

            DataResultsSettingsView(
                dataGrid: $settingsManager.dataGrid,
                history: $settingsManager.history,
                editor: $settingsManager.editor
            )
            .tabItem { Label("Data & Results", systemImage: "tablecells") }
            .tag(SettingsTab.data.rawValue)

            SidebarSettingsView(general: $settingsManager.general)
                .tabItem { Label("Sidebar", systemImage: "sidebar.left") }
                .tag(SettingsTab.sidebar.rawValue)

            KeyboardSettingsView(settings: $settingsManager.keyboard)
                .tabItem { Label("Keyboard", systemImage: "keyboard") }
                .tag(SettingsTab.keyboard.rawValue)

            AISettingsView(settings: $settingsManager.ai)
                .tabItem { Label("AI", systemImage: "sparkles") }
                .tag(SettingsTab.ai.rawValue)

            MCPSettingsView(settings: $settingsManager.mcp)
                .tabItem { Label("Integrations", systemImage: "network") }
                .tag(SettingsTab.mcp.rawValue)

            PluginsSettingsView()
                .tabItem { Label("Plugins", systemImage: "puzzlepiece.extension") }
                .badge(pluginAttentionCount)
                .tag(SettingsTab.plugins.rawValue)

            AccountSettingsView()
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
                .tag(SettingsTab.account.rawValue)
        }
        .frame(width: 720, height: 500)
    }
}

#Preview {
    SettingsView()
        .environment(UpdaterBridge.shared)
}
