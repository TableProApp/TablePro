//
//  SettingsView.swift
//  TablePro
//

import SwiftUI

enum SettingsTab: String {
    case general, appearance, editor, keyboard, ai, terminal, mcp, plugins, account
}

struct SettingsView: View {
    @Bindable private var settingsManager = AppSettingsManager.shared
    @Environment(UpdaterBridge.self) var updaterBridge
    @AppStorage("selectedSettingsTab") private var selectedTab: String = SettingsTab.general.rawValue

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsView(
                settings: $settingsManager.general,
                tabSettings: $settingsManager.tabs,
                historySettings: $settingsManager.history,
                updaterBridge: updaterBridge,
                onResetAll: { settingsManager.resetToDefaults() }
            )
            .tabItem { Label("General", systemImage: "gearshape") }
            .tag(SettingsTab.general.rawValue)

            AppearanceSettingsView(settings: $settingsManager.appearance)
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
                .tag(SettingsTab.appearance.rawValue)

            EditorSettingsView(
                settings: $settingsManager.editor,
                dataGridSettings: $settingsManager.dataGrid
            )
            .tabItem { Label("Editor", systemImage: "doc.text") }
            .tag(SettingsTab.editor.rawValue)

            KeyboardSettingsView(settings: $settingsManager.keyboard)
                .tabItem { Label("Keyboard", systemImage: "keyboard") }
                .tag(SettingsTab.keyboard.rawValue)

            AISettingsView(settings: $settingsManager.ai)
                .tabItem { Label("AI", systemImage: "sparkles") }
                .tag(SettingsTab.ai.rawValue)

            TerminalSettingsView(settings: $settingsManager.terminal)
                .tabItem { Label("Terminal", systemImage: "terminal") }
                .tag(SettingsTab.terminal.rawValue)

            MCPSettingsView(settings: $settingsManager.mcp)
                .tabItem { Label("MCP", systemImage: "network") }
                .tag(SettingsTab.mcp.rawValue)

            PluginsSettingsView()
                .tabItem { Label("Plugins", systemImage: "puzzlepiece.extension") }
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
        .environment(UpdaterBridge())
}
