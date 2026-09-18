import SwiftUI

struct AWSDiscoveryProgressStep: View {
    /// Observed, because every row reads `regionProgress` and the discovery writes it region by
    /// region while this step is on screen. Held as a plain property the rows were drawn once, as
    /// pending, and stayed that way until the step was replaced.
    @ObservedObject var session: AWSDiscoverySession
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            List(session.selectedRegionIds, id: \.self) { region in
                regionRow(region)
            }
            .listStyle(.inset)
            Divider()
            footer
        }
    }

    private var header: some View {
        HStack {
            ProgressView()
                .controlSize(.small)
            Text("Looking for RDS instances and Aurora clusters")
                .font(.body.weight(.semibold))
            Spacer()
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
    }

    private func regionRow(_ region: String) -> some View {
        HStack(spacing: 8) {
            statusIcon(for: session.regionProgress[region] ?? .pending)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: AWSRegionCatalog.displayName(for: region))
                Text(verbatim: statusText(for: session.regionProgress[region] ?? .pending, region: region))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func statusIcon(for progress: AWSDiscoverySession.RegionProgress) -> some View {
        switch progress {
        case .pending:
            Image(systemName: "circle.dotted")
                .foregroundStyle(.secondary)
               .accessibilityLabel(String(localized: "Not started"))
        case .loading:
            ProgressView()
                .controlSize(.small)
        case .loaded:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
               .accessibilityLabel(String(localized: "Done"))
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
               .accessibilityLabel(String(localized: "Failed"))
        }
    }

    private func statusText(for progress: AWSDiscoverySession.RegionProgress, region: String) -> String {
        switch progress {
        case .pending:
            return region
        case .loading:
            return String(localized: "Searching…")
        case .loaded(let count):
            return count == 1
                ? String(localized: "1 database")
                : String(format: String(localized: "%d databases"), count)
        case .failed(let message):
            return message
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(String(localized: "Cancel")) { onCancel() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(12)
    }
}
