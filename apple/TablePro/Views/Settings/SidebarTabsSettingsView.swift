import SwiftUI

struct SidebarTabsSettingsView: View {
    @Binding var settings: GeneralSettings
    @Binding var tabSettings: TabSettings

    @AppStorage(SidebarPersistenceKey.defaultLayout, store: AppStorageEnvironment.shared.defaults)
    private var defaultSidebarLayout: SidebarLayout = .fallback

    var body: some View {
        Form {
            Section("Sidebar") {
                Toggle(isOn: $settings.showWorkspaceRail) {
                    Text("Show connections")
                    Text("A strip on the window's leading edge with each open connection and database. It appears once more than one is open.")
                }
                .accessibilityIdentifier("show-connections-toggle")

                Toggle("Show recent tables", isOn: $settings.showRecentTables)
                    .accessibilityIdentifier("show-recent-tables-toggle")

                Picker(selection: $defaultSidebarLayout) {
                    Text("List").tag(SidebarLayout.flat)
                    Text("Tree").tag(SidebarLayout.tree)
                } label: {
                    Text("Default layout")
                    Text("Used when a connection opens, unless you picked a layout for it from the View menu. For servers with a database tree.")
                }
                .accessibilityIdentifier("sidebar-default-layout-picker")
            }

            // Same set and order as the sidebar's View Options menu, so the two map one to one.
            Section("Objects") {
                Toggle("Show icons", isOn: $settings.showObjectIcons)
                    .accessibilityIdentifier("show-object-icons-toggle")

                Toggle(isOn: $settings.showObjectComments) {
                    Text("Show comments")
                    Text("In the sidebar, the inspector and data grid column header tooltips.")
                }
                .accessibilityIdentifier("show-object-comments-toggle")

                Toggle(isOn: $settings.showSystemContainers) {
                    Text("Show system databases and schemas")
                    Text("Such as mysql and information_schema, in the sidebar and its database filter. The database switcher always lists them.")
                }
                .accessibilityIdentifier("show-system-containers-toggle")

                Toggle("Show partitions", isOn: $settings.showPartitions)
                    .accessibilityIdentifier("show-partitions-toggle")

                Picker(selection: $settings.sidebarRowSize) {
                    ForEach(SidebarRowSizePreference.allCases, id: \.self) { size in
                        Text(size.title).tag(size)
                    }
                } label: {
                    Text("Row size")
                    Text("Match System follows Sidebar icon size in System Settings.")
                }
                .accessibilityIdentifier("sidebar-row-size-picker")
            }

            Section("Tabs") {
                Toggle(isOn: $tabSettings.enablePreviewTabs) {
                    Text("Enable preview tabs")
                    Text("Clicking a table opens it in a preview tab that the next click reuses. Double-click a table or press Return to keep its tab.")
                }
                .accessibilityIdentifier("preview-tabs-toggle")
            }
        }
        .formStyle(.grouped)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-pane-sidebar")
    }
}

#Preview {
    SidebarTabsSettingsView(settings: .constant(.default), tabSettings: .constant(.default))
        .frame(width: 520, height: 760)
}
