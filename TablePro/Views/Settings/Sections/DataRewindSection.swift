//
//  DataRewindSection.swift
//  TablePro
//

import SwiftUI

struct DataRewindSection: View {
    @Binding var settings: HistorySettings

    private var isAvailable: Bool {
        LicenseManager.shared.isFeatureAvailable(.dataRewind)
    }

    var body: some View {
        Section("Data Rewind") {
            Toggle("Keep saved changes for restoring", isOn: $settings.keepRewindHistory)
                .disabled(!isAvailable)

            Text(explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LabeledContent("Clear saved changes") {
                Button("Clear Saved Changes…") {
                    Task { @MainActor in
                        let confirmed = await AlertHelper.confirmDestructive(
                            title: String(localized: "Clear Saved Changes?"),
                            message: String(
                                localized: "Saves already committed stay committed. You will not be able to restore their previous values."
                            ),
                            confirmButton: String(localized: "Clear"),
                            cancelButton: String(localized: "Cancel")
                        )
                        guard confirmed else { return }
                        Task { _ = await QueryHistoryManager.shared.clearRewindSnapshots() }
                    }
                }
                .disabled(!isAvailable)
            }
        }
    }

    private var explanation: String {
        guard isAvailable else {
            return String(localized: "Restoring a save that already committed needs a Starter license.")
        }
        return String(
            localized: "Keeps what rows looked like before each save, on this Mac only, for 7 days. It is encrypted, and never synced."
        )
    }
}
