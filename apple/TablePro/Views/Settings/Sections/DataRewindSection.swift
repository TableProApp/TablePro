import SwiftUI

struct DataRewindPage: View {
    @ObservedObject var history: SettingsSlice<HistorySettings>
    let context: SettingsPaneContext
    @ObservedObject private var featureAccess = FeatureAccess.shared
    @State private var isClearing = false

    init(history: SettingsSlice<HistorySettings>, context: SettingsPaneContext) {
        self.history = history
        self.context = context
    }

    var body: some View {
        let isAvailable = featureAccess.isAvailable(.dataRewind)
        Form {
            if !isAvailable {
                Section {
                    LicenseGateRow(feature: .dataRewind)
                }
            }

            Section {
                Toggle(isOn: Self.keepBinding($history.value, isAvailable: isAvailable)) {
                    Text("Keep saved changes for restoring")
                    Text("Keeps what rows looked like before each save, for 7 days, on this Mac only. Encrypted and never synced.")
                }
                .disabled(!isAvailable)
                .accessibilityIdentifier("rewind-keep-toggle")
            }

            // Never license gated: saved changes from a lapsed license can still be cleared.
            Section {
                LabeledContent {
                    Button("Clear Saved Changes…", action: confirmClear)
                        .disabled(isClearing)
                        .accessibilityIdentifier("rewind-clear-button")
                } label: {
                    Text("Clear saved changes")
                    Text("Committed saves stay committed. Their previous values can no longer be restored.")
                }
            }
        }
        .formStyle(.grouped)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(SettingsPage.dataRewind.pageIdentifier)
    }

    static func isOn(_ settings: HistorySettings, isAvailable: Bool) -> Bool {
        isAvailable && settings.keepRewindHistory
    }

    // Reads off without a license but never writes that, so the choice returns with the license.
    static func keepBinding(_ settings: Binding<HistorySettings>, isAvailable: Bool) -> Binding<Bool> {
        Binding(
            get: { isOn(settings.wrappedValue, isAvailable: isAvailable) },
            set: { settings.wrappedValue.keepRewindHistory = $0 }
        )
    }

    private func confirmClear() {
        let context = context
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
            isClearing = true
            let cleared = await SettingsClearing.run([
                { await QueryHistoryManager.shared.clearRewindSnapshots() },
            ])
            isClearing = false
            if !cleared {
                context.presentError(
                    title: String(localized: "Couldn't Clear Saved Changes"),
                    message: String(localized: "The saved changes couldn't be deleted. Try again.")
                )
            }
        }
    }
}

struct DataRewindDrillRow: View {
    @ObservedObject var history: SettingsSlice<HistorySettings>
    @ObservedObject private var featureAccess = FeatureAccess.shared

    init(history: SettingsSlice<HistorySettings>) {
        self.history = history
    }

    var body: some View {
        let isOn = DataRewindPage.isOn(history.value, isAvailable: featureAccess.isAvailable(.dataRewind))
        SettingsDrillRow(
            route: SettingsRoute.page(.dataRewind),
            title: SettingsPage.dataRewind.title,
            value: isOn ? String(localized: "On") : String(localized: "Off")
        )
    }
}
