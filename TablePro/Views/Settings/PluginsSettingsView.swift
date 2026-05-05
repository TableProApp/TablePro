//
//  PluginsSettingsView.swift
//  TablePro
//

import SwiftUI

struct PluginsSettingsView: View {
    @State private var selectedTab: PluginsSubTab = .installed

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                Text(String(localized: "Installed")).tag(PluginsSubTab.installed)
                Text(String(localized: "Browse")).tag(PluginsSubTab.browse)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 280)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Group {
                switch selectedTab {
                case .installed:
                    InstalledPluginsView()
                case .browse:
                    BrowsePluginsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
