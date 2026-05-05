//
//  SettingsView.swift
//  TablePro
//

import SwiftUI

struct SettingsView: View {
    @Bindable private var settingsManager = AppSettingsManager.shared
    @Environment(UpdaterBridge.self) var updaterBridge
    @AppStorage("selectedSettingsTab") private var selectedTabRaw: String = SettingsTab.general.rawValue

    @State private var selection: SettingsTab? = .general

    var body: some View {
        NavigationSplitView {
            SettingsSidebar(selection: $selection)
        } detail: {
            detail
        }
        .frame(minWidth: 720, minHeight: 540)
        .onAppear {
            selection = SettingsTab(rawValue: selectedTabRaw) ?? .general
        }
        .onChange(of: selection) { _, new in
            if let new {
                selectedTabRaw = new.rawValue
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            let storedRaw = UserDefaults.standard.string(forKey: "selectedSettingsTab")
                ?? SettingsTab.general.rawValue
            if let stored = SettingsTab(rawValue: storedRaw), stored != selection {
                selection = stored
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .general {
        case .general:
            GeneralSettingsView(
                settings: $settingsManager.general,
                tabSettings: $settingsManager.tabs,
                historySettings: $settingsManager.history,
                updaterBridge: updaterBridge,
                onResetAll: { settingsManager.resetToDefaults() }
            )
        case .appearance:
            AppearanceSettingsView(settings: $settingsManager.appearance)
        case .editor:
            EditorSettingsView(
                settings: $settingsManager.editor,
                dataGridSettings: $settingsManager.dataGrid
            )
        case .keyboard:
            KeyboardSettingsView(settings: $settingsManager.keyboard)
        case .ai:
            AISettingsView(settings: $settingsManager.ai)
        case .terminal:
            TerminalSettingsView(settings: $settingsManager.terminal)
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
