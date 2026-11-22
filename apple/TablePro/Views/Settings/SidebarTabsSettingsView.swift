//
//  SidebarTabsSettingsView.swift
//  TablePro
//

import SwiftUI

struct SidebarTabsSettingsView: View {
    @Binding var settings: GeneralSettings
    @Binding var tabSettings: TabSettings

    @AppStorage(SidebarPersistenceKey.defaultLayout, store: AppStorageEnvironment.shared.defaults)
    private var defaultSidebarLayout: SidebarLayout = .flat

    var body: some View {
        Form {
            Section("Tabs") {
                Toggle("Enable preview tabs", isOn: $tabSettings.enablePreviewTabs)
                    .help("Single-clicking a table opens a temporary tab that gets replaced on next click.")
            }

            Section("Sidebar") {
                Toggle("Show connections", isOn: $settings.showWorkspaceRail)
                    .help("Adds a narrow strip on the window's leading edge listing every connection and database you have open, so one click switches to it.")

                Toggle("Show recent tables", isOn: $settings.showRecentTables)
                    .help("Adds a Recent section at the top of the Tables sidebar with the last tables you opened per connection and database.")

                Toggle("Show object icons", isOn: $settings.showObjectIcons)
                    .help("Shows a type icon before each object name in the sidebar. Turn it off for a plain list of names.")

                Toggle("Show object comments", isOn: $settings.showObjectComments)
                    .help("Shows database object comments next to tables in the sidebar and in grid column headers.")

                Toggle("Show system databases and schemas", isOn: $settings.showSystemContainers)
                    .accessibilityIdentifier("show-system-containers-toggle")
                    .help(String(localized: """
                        Lists system databases such as mysql and information_schema, and system schemas, \
                        in the sidebar tree and the database filter. Switchers always list them.
                        """))

                Toggle("Show partitions", isOn: $settings.showPartitions)
                    .accessibilityIdentifier("show-partitions-toggle")
                    .help(String(localized: """
                        Lists a partitioned table's partitions under it in the sidebar, with how many \
                        it holds. Turn it off to keep partitioned tables as single rows.
                        """))

                Picker("Row size:", selection: $settings.sidebarRowSize) {
                    ForEach(SidebarRowSizePreference.allCases, id: \.self) { size in
                        Text(size.title).tag(size)
                    }
                }
                .help(String(localized: """
                    Match System follows Sidebar icon size in System Settings > Appearance. \
                    Choose a size to fit more objects on screen than the rest of the system shows.
                    """))

                Picker("Default layout for new connections:", selection: $defaultSidebarLayout) {
                    Text("List").tag(SidebarLayout.flat)
                    Text("Tree").tag(SidebarLayout.tree)
                }
                .help(String(localized: "Layout for new connections on servers that support a database tree. Switch the current connection from the View menu."))
            }
        }
        .formStyle(.grouped)
    }
}

#Preview {
    SidebarTabsSettingsView(settings: .constant(.default), tabSettings: .constant(.default))
        .frame(width: 520, height: 500)
}
