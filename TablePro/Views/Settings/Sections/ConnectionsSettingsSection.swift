//
//  ConnectionsSettingsSection.swift
//  TablePro
//

import SwiftUI
import TableProConnectionLibrary

internal struct ConnectionsSettingsSection: View {
    @Binding private var healthCheck: ConnectionHealthCheck
    @ObservedObject private var listPreferences: ConnectionListPreferences
    @ObservedObject private var recentConnections: RecentConnectionsStore

    internal init(
        healthCheck: Binding<ConnectionHealthCheck>,
        listPreferences: ConnectionListPreferences = .shared,
        recentConnections: RecentConnectionsStore = .shared
    ) {
        _healthCheck = healthCheck
        self.listPreferences = listPreferences
        self.recentConnections = recentConnections
    }

    private var showsRecent: Binding<Bool> {
        Binding(
            get: { listPreferences.showsRecent },
            set: { listPreferences.setShowsRecent($0) }
        )
    }

    internal var body: some View {
        Section("Connections") {
            Toggle("Show recent connections", isOn: showsRecent)
                .accessibilityIdentifier("show-recent-connections-toggle")
                .help(String(localized: """
                    Adds a Recent section with the connections you opened lately to the welcome window \
                    and the connection switcher.
                    """))

            LabeledContent("Recent connection history") {
                Button("Clear Recent") {
                    recentConnections.clear()
                }
                .disabled(recentConnections.ledger.isEmpty)
                .accessibilityIdentifier("clear-recent-connections-button")
                .help(String(localized: "Forgets which connections you opened and when. Sorting by Last Connected starts over."))
            }

            Picker("Check connections:", selection: $healthCheck) {
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
    }
}
