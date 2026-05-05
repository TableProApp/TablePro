//
//  PluginsSettingsView.swift
//  TablePro
//

import SwiftUI

struct PluginsSettingsView: View {
    @State private var selectedTab: PluginsSubTab = .installed

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(String(localized: "Plugins"))
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Picker("", selection: $selectedTab) {
                            Text(String(localized: "Installed")).tag(PluginsSubTab.installed)
                            Text(String(localized: "Browse")).tag(PluginsSubTab.browse)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 240)
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch selectedTab {
        case .installed:
            InstalledPluginsView()
        case .browse:
            BrowsePluginsView()
        }
    }
}

private enum PluginsSubTab: Hashable {
    case installed
    case browse
}

#Preview {
    PluginsSettingsView()
        .frame(width: 720, height: 500)
}
