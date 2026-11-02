import SwiftUI

struct PaneRefreshControls: View {
    let isRefreshing: Bool
    let lastRefreshDate: Date?
    let accessibilityIdentifier: String
    let refresh: () -> Void

    var body: some View {
        if isRefreshing {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(String(localized: "Refreshing"))
        } else if let lastRefreshDate {
            Text(lastRefreshDate, style: .time)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .accessibilityLabel(String(localized: "Last updated"))
                .accessibilityValue(Text(lastRefreshDate, style: .time))
        }

        Button(action: refresh) {
            Label(String(localized: "Refresh"), systemImage: "arrow.clockwise")
        }
        .labelStyle(.iconOnly)
        .disabled(isRefreshing)
        .help(String(localized: "Refresh"))
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}
