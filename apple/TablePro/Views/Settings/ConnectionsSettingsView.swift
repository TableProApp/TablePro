import SwiftUI
import TableProConnectionLibrary

struct ConnectionsSettingsView: View {
    @Binding var settings: GeneralSettings
    private let listPreferences: ConnectionListPreferences
    private let recentConnections: RecentConnectionsStore

    init(
        settings: Binding<GeneralSettings>,
        listPreferences: ConnectionListPreferences = .shared,
        recentConnections: RecentConnectionsStore = .shared
    ) {
        _settings = settings
        self.listPreferences = listPreferences
        self.recentConnections = recentConnections
    }

    var body: some View {
        Form {
            Section {
                Picker(selection: $settings.connectionHealthCheck) {
                    ForEach(ConnectionHealthCheck.allCases.filter { $0.interval != nil }) { option in
                        Text(option.title).tag(option)
                    }
                    Divider()
                    Text(ConnectionHealthCheck.onDemand.title).tag(ConnectionHealthCheck.onDemand)
                } label: {
                    Text("Check open connections")
                    Text(
                        """
                        A small query on each open connection catches a drop early. For a database that sleeps \
                        when idle or bills per query, pick Only when used: it checks when you next use the connection.
                        """
                    )
                }
                .accessibilityIdentifier("connection-health-check-picker")

                Picker(selection: $settings.queryTimeoutSeconds) {
                    ForEach(GeneralSettings.queryTimeoutChoices(including: settings.queryTimeoutSeconds), id: \.self) { seconds in
                        Text(verbatim: GeneralSettings.queryTimeoutTitle(seconds)).tag(seconds)
                    }
                    Divider()
                    Text("No limit").tag(0)
                } label: {
                    Text("Query timeout")
                    Text(
                        "Stops longer queries on drivers that support it. A connection's own timeout overrides this. Applies to connections opened after a change."
                    )
                }
                .accessibilityIdentifier("query-timeout-picker")
            }

            RecentConnectionsSection(listPreferences: listPreferences, recentConnections: recentConnections)

            ConnectionsPagesSection()
        }
        .formStyle(.grouped)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-pane-connections")
    }
}

private struct RecentConnectionsSection: View {
    @ObservedObject var listPreferences: ConnectionListPreferences
    @ObservedObject var recentConnections: RecentConnectionsStore

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { listPreferences.showsRecent }, set: { listPreferences.setShowsRecent($0) })) {
                Text("Show recent connections")
                Text("Adds a Recent section to the welcome window and the connection switcher.")
            }
            .accessibilityIdentifier("show-recent-connections-toggle")

            // Stays enabled while Recent is hidden: the history also drives the Last Connected sort.
            LabeledContent {
                Button(String(localized: "Clear Recent")) {
                    recentConnections.clear()
                }
                .disabled(recentConnections.ledger.isEmpty)
                .accessibilityLabel(Text("Clear Recent Connections"))
                .accessibilityIdentifier("clear-recent-connections-button")
            } label: {
                Text("Connection history")
                Text("When you last opened each connection, used by Recent and the Last Connected sort. Stays on this Mac.")
            }
        } header: {
            Text("Recent Connections")
        }
    }
}

private struct ConnectionsPagesSection: View {
    @EnvironmentObject private var linkedFolders: LinkedFoldersModel
    @EnvironmentObject private var trustedLinks: TrustedLinksModel

    var body: some View {
        Section {
            SettingsDrillRow(
                route: SettingsRoute.page(.linkedFolders),
                title: SettingsPage.linkedFolders.title,
                value: SettingsFormat.count(linkedFolders.folders.count)
            )
            SettingsDrillRow(
                route: SettingsRoute.page(.trustedLinks),
                title: SettingsPage.trustedLinks.title,
                value: SettingsFormat.count(trustedLinks.entries.count)
            )
        }
    }
}
