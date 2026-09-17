//
//  GeneralSettingsView.swift
//  TablePro
//

import AppKit
import SwiftUI

struct GeneralSettingsView: View {
    @Binding var settings: GeneralSettings
    @Binding var tabSettings: TabSettings
    var updater: SoftwareUpdater
    var onResetAll: () -> Void

    @State private var initialLanguage: AppLanguage?
    @State private var showResetConfirmation = false
    @AppStorage(SidebarPersistenceKey.defaultLayout, store: AppStorageEnvironment.shared.defaults) private var defaultSidebarLayout: SidebarLayout = .flat

    private static let standardTimeouts = [10, 20, 30, 40, 50, 60, 90, 120, 180, 300, 600]

    /// Bindings straight onto Sparkle's own properties. Nothing about the update section is stored
    /// in `GeneralSettings`, so there is no second copy to fall out of step and nothing for a
    /// synced settings blob to overwrite on another Mac.
    private var automaticallyChecksForUpdates: Binding<Bool> {
        Binding(
            get: { updater.automaticallyChecksForUpdates },
            set: { updater.setAutomaticallyChecksForUpdates($0) }
        )
    }

    private var automaticallyDownloadsUpdates: Binding<Bool> {
        Binding(
            get: { updater.automaticallyDownloadsUpdates },
            set: { updater.setAutomaticallyDownloadsUpdates($0) }
        )
    }

    private var lastUpdateCheckDescription: String {
        guard let date = updater.lastUpdateCheckDate else {
            return String(localized: "Last checked: never")
        }
        return String(
            format: String(localized: "Last checked: %@"),
            date.formatted(date: .abbreviated, time: .shortened)
        )
    }

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
                Text("Restart TablePro for the language change to take full effect.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

            Section("Connections") {
                Picker("Check connections:", selection: $settings.connectionHealthCheck) {
                    ForEach(ConnectionHealthCheck.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .accessibilityIdentifier("connection-health-check-picker")
                .help(String(localized: """
                    TablePro runs a small query on each open connection so it can notice a dropped \
                    one and reconnect before you hit it. Only when I use the connection stops that \
                    background traffic, which is what a database that sleeps when idle, or bills \
                    per query, needs; TablePro then checks the connection the first time you use \
                    it after a pause.
                    """))
            }

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

            Section {
                Toggle("Automatically check for updates", isOn: automaticallyChecksForUpdates)
                    .accessibilityIdentifier("automatic-update-check-toggle")

                Toggle("Download and install updates automatically", isOn: automaticallyDownloadsUpdates)
                    .disabled(!updater.allowsAutomaticUpdates)
                    .accessibilityIdentifier("automatic-update-install-toggle")
                    .help(String(localized: "A new version downloads in the background and installs the next time you quit TablePro."))

                LabeledContent {
                    Button(updater.checkForUpdatesTitle) {
                        updater.checkForUpdates()
                    }
                    .disabled(!updater.canCheckForUpdates)
                    .accessibilityIdentifier("check-for-updates-button")
                } label: {
                    Text(lastUpdateCheckDescription)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("last-update-check-label")
                }
                .accessibilityElement(children: .contain)

                Button {
                    NSApp.sendAction(#selector(AppDelegate.openChangelog(_:)), to: nil, from: nil)
                } label: {
                    Text(String(localized: "What's New"))
                }
                .buttonStyle(.link)
                .accessibilityIdentifier("whats-new-link")
            } header: {
                Text("Software Update")
            }

            Section {
                Toggle("Share anonymous usage data", isOn: $settings.shareAnalytics)
            } header: {
                Text("Privacy")
            } footer: {
                Text("Help improve TablePro by sharing anonymous usage statistics (no personal data or queries).")
            }

            Section {
                Button(String(localized: "Reset All Settings to Defaults"), role: .destructive) {
                    showResetConfirmation = true
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
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
