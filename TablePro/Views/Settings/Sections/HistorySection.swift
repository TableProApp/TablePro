//
//  HistorySection.swift
//  TablePro
//

import SwiftUI

struct HistorySection: View {
    @Binding var settings: HistorySettings

    var body: some View {
        Section("Query History") {
            Picker("Maximum entries:", selection: $settings.maxEntries) {
                Text("100").tag(100)
                Text("500").tag(500)
                Text("1,000").tag(1_000)
                Text("5,000").tag(5_000)
                Text("10,000").tag(10_000)
                Text("Unlimited").tag(0)
            }

            Picker("Keep entries for:", selection: $settings.maxDays) {
                Text("7 days").tag(7)
                Text("30 days").tag(30)
                Text("90 days").tag(90)
                Text("1 year").tag(365)
                Text("Forever").tag(0)
            }

            Toggle("Auto cleanup on startup", isOn: $settings.autoCleanup)

            LabeledContent("Clear all query history") {
                Button("Clear History...") {
                    Task { @MainActor in
                        let confirmed = await AlertHelper.confirmDestructive(
                            title: String(localized: "Clear All History?"),
                            message: String(localized: "This will permanently delete all query history entries. This action cannot be undone."),
                            confirmButton: String(localized: "Clear"),
                            cancelButton: String(localized: "Cancel")
                        )
                        if confirmed {
                            Task { _ = await QueryHistoryManager.shared.clearAllHistory() }
                        }
                    }
                }
            }
        }
    }
}
