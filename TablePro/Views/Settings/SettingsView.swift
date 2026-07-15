//
//  SettingsView.swift
//  TablePro
//

import SwiftUI

enum SettingsPane: String {
    case general, appearance, editor, data, keyboard, ai, mcp, plugins, account

    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .appearance: String(localized: "Appearance")
        case .editor: String(localized: "Editor")
        case .data: String(localized: "Data")
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
    @AppStorage(PreferenceKeys.selectedSettingsPane.name) private var selectedTab = SettingsPane.general.rawValue
    private let pluginManager = PluginManager.shared

    private var pluginAttentionCount: Int {
        pluginManager.rejectedPlugins.count + pluginManager.pluginsWithRegistryUpdate.count
    }

    private var selection: Binding<String> {
        Binding(
            get: { SettingsPane(rawValue: selectedTab) == nil ? SettingsPane.general.rawValue : selectedTab },
            set: { selectedTab = $0 }
        )
    }

    var body: some View {
        TabView(selection: selection) {
            GeneralSettingsView(
                settings: $settingsManager.general,
                tabSettings: $settingsManager.tabs,
                updaterBridge: updaterBridge,
                onResetAll: { settingsManager.resetToDefaults() }
            )
            .tabItem { Label(SettingsPane.general.title, systemImage: SettingsPane.general.symbol) }
            .tag(SettingsPane.general.rawValue)

            AppearanceSettingsView(settings: $settingsManager.appearance)
                .tabItem { Label(SettingsPane.appearance.title, systemImage: SettingsPane.appearance.symbol) }
                .tag(SettingsPane.appearance.rawValue)

            EditorSettingsView(settings: $settingsManager.editor)
                .tabItem { Label(SettingsPane.editor.title, systemImage: SettingsPane.editor.symbol) }
                .tag(SettingsPane.editor.rawValue)

            DataResultsSettingsView(
                dataGrid: $settingsManager.dataGrid,
                history: $settingsManager.history,
                editor: $settingsManager.editor
            )
            .tabItem { Label(SettingsPane.data.title, systemImage: SettingsPane.data.symbol) }
            .tag(SettingsPane.data.rawValue)

            KeyboardSettingsView(settings: $settingsManager.keyboard)
                .tabItem { Label(SettingsPane.keyboard.title, systemImage: SettingsPane.keyboard.symbol) }
                .tag(SettingsPane.keyboard.rawValue)

            AISettingsView(settings: $settingsManager.ai)
                .tabItem { Label(SettingsPane.ai.title, systemImage: SettingsPane.ai.symbol) }
                .tag(SettingsPane.ai.rawValue)

            MCPSettingsView(settings: $settingsManager.mcp)
                .tabItem { Label(SettingsPane.mcp.title, systemImage: SettingsPane.mcp.symbol) }
                .tag(SettingsPane.mcp.rawValue)

            PluginsSettingsView()
                .tabItem { Label(SettingsPane.plugins.title, systemImage: SettingsPane.plugins.symbol) }
                .badge(pluginAttentionCount)
                .tag(SettingsPane.plugins.rawValue)

            AccountSettingsView()
                .tabItem { Label(SettingsPane.account.title, systemImage: SettingsPane.account.symbol) }
                .tag(SettingsPane.account.rawValue)
        }
        .frame(width: 720, height: 500)
    }
}

#Preview {
    SettingsView()
        .environment(UpdaterBridge.shared)
}
