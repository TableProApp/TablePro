//
//  ConnectionsSettingsView.swift
//  TablePro
//

import SwiftUI

struct ConnectionsSettingsView: View {
    @Binding var settings: GeneralSettings

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
        }
        .formStyle(.grouped)
    }
}

#Preview {
    ConnectionsSettingsView(settings: .constant(.default))
        .frame(width: 520, height: 400)
}
