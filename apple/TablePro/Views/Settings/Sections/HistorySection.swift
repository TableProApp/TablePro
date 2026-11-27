import SwiftUI

struct QueryHistorySettingsPage: View {
    static let maxEntries = [100, 500, 1_000, 5_000, 10_000, 0]
    static let retentionDays = [7, 30, 90, 365, 0]

    @ObservedObject var history: SettingsSlice<HistorySettings>
    let context: SettingsPaneContext
    @State private var isClearing = false

    init(history: SettingsSlice<HistorySettings>, context: SettingsPaneContext) {
        self.history = history
        self.context = context
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $history.value.autoCleanup) {
                    Text("Remove old entries automatically")
                    Text(
                        """
                        Removes entries past these limits at launch, every 100 queries and when a limit changes. \
                        Removed entries can't be recovered.
                        """
                    )
                }
                .accessibilityIdentifier("history-auto-cleanup-toggle")

                Picker("Maximum entries", selection: $history.value.maxEntries) {
                    SettingsChoiceItems(Self.maxEntries, including: history.value.maxEntries) { count in
                        Text(Self.maxEntriesTitle(count))
                    }
                }
                .disabled(!history.value.autoCleanup)
                .accessibilityIdentifier("history-max-entries-picker")

                // Stays enabled while cleanup is off: it also bounds how long query tab versions are kept.
                Picker(selection: $history.value.maxDays) {
                    SettingsChoiceItems(Self.retentionDays, including: history.value.maxDays) { days in
                        Text(Self.retentionTitle(days))
                    }
                } label: {
                    Text("Keep entries for")
                    Text("Earlier versions of query tabs are kept this long too, up to 30 days.")
                }
                .accessibilityIdentifier("history-max-days-picker")
            }

            Section {
                LabeledContent {
                    Button("Clear History…", action: confirmClear)
                        .disabled(isClearing)
                        .accessibilityIdentifier("history-clear-button")
                } label: {
                    Text("Clear query history")
                    Text("Also deletes saved changes kept for Data Rewind and earlier versions of query tabs.")
                }
            }
        }
        .formStyle(.grouped)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(SettingsPage.queryHistory.pageIdentifier)
    }

    static func maxEntriesTitle(_ count: Int) -> String {
        count == 0 ? String(localized: "No limit") : SettingsFormat.count(count)
    }

    static func retentionTitle(_ days: Int) -> String {
        days == 0 ? String(localized: "Forever") : SettingsFormat.days(days)
    }

    private func confirmClear() {
        let context = context
        Task { @MainActor in
            let confirmed = await AlertHelper.confirmDestructive(
                title: String(localized: "Clear All History?"),
                message: String(
                    localized: """
                        This will permanently delete all query history entries, the saved changes kept \
                        for restoring, and the earlier versions of your query tabs. This action cannot \
                        be undone.
                        """
                ),
                confirmButton: String(localized: "Clear"),
                cancelButton: String(localized: "Cancel")
            )
            guard confirmed else { return }
            isClearing = true
            let cleared = await SettingsClearing.run([
                { await QueryHistoryManager.shared.clearEverything() },
                { await QueryHistoryManager.shared.clearRewindSnapshots() },
                { await QueryTabVersionStorage.shared.removeAll() },
            ])
            isClearing = false
            if !cleared {
                context.presentError(
                    title: String(localized: "Couldn't Clear Query History"),
                    message: String(localized: "Part of the history couldn't be deleted. Try again.")
                )
            }
        }
    }
}

enum SettingsClearing {
    // Every step runs even after one fails, so a failed history delete still clears the rest.
    @MainActor
    static func run(_ steps: [@MainActor () async -> Bool]) async -> Bool {
        var cleared = true
        for step in steps {
            let succeeded = await step()
            cleared = cleared && succeeded
        }
        return cleared
    }
}
