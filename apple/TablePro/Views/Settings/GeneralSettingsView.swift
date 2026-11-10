import AppKit
import SwiftUI

struct GeneralSettingsView: View {
    @Binding var settings: GeneralSettings
    @Binding var tabSettings: TabSettings
    @ObservedObject var updater: SoftwareUpdater
    var onResetAll: () -> Void

    @State private var initialLanguage: AppLanguage?
    @State private var showResetConfirmation = false
    @AppStorage(SidebarPersistenceKey.defaultLayout, store: AppStorageEnvironment.shared.defaults) private var defaultSidebarLayout: SidebarLayout = .flat

    private static let standardTimeouts = [10, 20, 30, 40, 50, 60, 90, 120, 180, 300, 600]

    private var queryTimeoutOptions: [Int] {
        let current = settings.queryTimeoutSeconds
        if current > 0, !Self.standardTimeouts.contains(current) {
            return (Self.standardTimeouts + [current]).sorted()
        }
        return Self.standardTimeouts
    }

    var body: some View {
        Form {
            Picker("Language:", selection: $settings.language) {
                ForEach(AppLanguage.allCases) { lang in
                    Text(lang.displayName).tag(lang)
                }
            }

            if let initial = initialLanguage, settings.language != initial {
                LabeledContent {
                    Button(String(localized: "Relaunch")) {
                        UpdateCenter.shared.relaunch()
                    }
                    .accessibilityIdentifier("language-relaunch-button")
                } label: {
                    Text("Relaunch TablePro to finish switching languages.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Picker("When TablePro starts:", selection: $settings.startupBehavior) {
                ForEach(StartupBehavior.allCases) { behavior in
                    Text(behavior.displayName).tag(behavior)
                }
            }

            Section("Tabs") {
                Toggle("Enable preview tabs", isOn: $tabSettings.enablePreviewTabs)
                    .help("Single-clicking a table opens a temporary tab that gets replaced on next click.")

                Picker("When tabs stop fitting:", selection: $tabSettings.overflow) {
                    ForEach(EditorTabStripOverflow.allCases, id: \.self) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .help("Scrolling keeps one row of tabs, the way every macOS tab bar does. Rows wraps them so nothing is off screen.")
            }

            Section {
                HStack {
                    Button(String(localized: "Use Navigator Layout")) {
                        useLayoutPreset(navigator: true)
                    }
                    Button(String(localized: "Use Standard Layout")) {
                        useLayoutPreset(navigator: false)
                    }
                }
            } header: {
                Text("Layout")
            } footer: {
                Text(String(localized: """
                    Navigator Layout turns on table details, favorite tables at the top of the tree, the Objects \
                    tab on selection, the Objects toolbar buttons and the connections list, and makes Tree the \
                    default sidebar layout. Standard Layout turns them off again. Open connections switch layout too.
                    """))
            }

            Section("Sidebar") {
                Toggle("Show connections", isOn: $settings.showWorkspaceRail)
                    .help("Adds a narrow strip on the window's leading edge listing every connection and database you have open, so one click switches to it.")

                Toggle("List every saved connection beside the database tree", isOn: $settings.showsConnectionNavigator)
                    .help("Turns the connections column into a list of every saved connection, in its groups. Double-click one to open it.")

                Toggle("Show recent tables", isOn: $settings.showRecentTables)
                    .help("Adds a Recent section at the top of the Tables sidebar with the last tables you opened per connection and database.")

                Toggle("Show favorite tables at the top of the tree", isOn: $settings.showsFavoritesSection)
                    .help("Adds a Favorites section above Recent with the tables you starred in the database you are browsing. Each table also stays in its own place.")

                Toggle("Show objects when a database, schema or group is selected", isOn: $settings.showsObjectsOnSelection)
                    .help("Clicking a database, schema or object group in the sidebar lists its objects in the main area. Show Objects in the row's menu lists them either way.")

                Toggle("Show object buttons in the toolbar", isOn: $settings.showsObjectToolbar)
                    .help("Adds Tables, Views, Functions, Users, Query and Backup buttons to the connection window's toolbar. Customize Toolbar can move or remove them.")

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

            ConnectionsSettingsSection(healthCheck: $settings.connectionHealthCheck)

            Section("Query Execution") {
                Picker("Query timeout:", selection: $settings.queryTimeoutSeconds) {
                    Text("No limit").tag(0)
                    ForEach(queryTimeoutOptions, id: \.self) { seconds in
                        Text("\(seconds) seconds").tag(seconds)
                    }
                }
                .help(String(localized: "Maximum time to wait for a query to complete. Set to 0 for no limit. Applied to new connections."))
            }

            CommandLineToolSection()

            LinkedFoldersSection()

            TrustedExternalConnectionsSection()

            SoftwareUpdateSection(updater: updater, updates: .shared)

            Section {
                Toggle("Share usage data", isOn: $settings.shareAnalytics)
            } header: {
                Text("Privacy")
            } footer: {
                Text(
                    """
                    Sent to PostHog: app and macOS versions, Mac model, screen size, architecture, language, time zone, \
                    database types, connection count, first connection and query, plan prompts, sign-in and sign-out, \
                    and your account ID once you sign in. Never hostnames, credentials, queries, or rows.
                    """
                )
            }

            Section {
                Button(String(localized: "Reset All Settings to Defaults"), role: .destructive) {
                    showResetConfirmation = true
                }
            }
        }
        .formStyle(.grouped)
        .alert(String(localized: "Reset All Settings"), isPresented: $showResetConfirmation) {
            Button(String(localized: "Reset"), role: .destructive) { onResetAll() }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text("This will reset all settings across every section to their default values.")
        }
        .onAppear {
            if initialLanguage == nil { initialLanguage = settings.language }
        }
    }

    // Writes through the General settings binding and the same stored default the layout picker uses,
    // so every control below shows the result and each setting's own observers fire.
    private func useLayoutPreset(navigator: Bool) {
        if navigator {
            NavigatorLayoutPreset.apply(to: &settings, defaultLayout: &defaultSidebarLayout)
        } else {
            NavigatorLayoutPreset.restore(to: &settings, defaultLayout: &defaultSidebarLayout)
        }
        NavigatorLayoutPreset.switchOpenConnections(to: defaultSidebarLayout)
    }
}

#Preview {
    GeneralSettingsView(
        settings: .constant(.default),
        tabSettings: .constant(.default),
        updater: SoftwareUpdater.shared,
        onResetAll: {}
    )
    .frame(width: 450, height: 500)
}
