import SwiftUI
import TableProPluginKit

struct PrivilegeScopeRowView: View {
    let title: String
    let symbolName: String
    let isLoading: Bool
    let loadError: String?
    let isRestricted: Bool

    var body: some View {
        HStack(spacing: 6) {
            Label(title, systemImage: symbolName)
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)

            if isLoading {
                ProgressView()
                    .controlSize(.small)
            }
            if isRestricted {
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(.secondary)
                    .help(
                        String(
                            localized: """
                                Schema and table privileges in this database are only visible \
                                when the connection is using it.
                                """
                        )
                    )
                    .accessibilityLabel(String(localized: "Not browsable on this connection"))
            }
            if let loadError {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .help(loadError)
                    .accessibilityLabel(String(localized: "Failed to load"))
            }
        }
    }
}

struct ScopeSummaryView: View {
    let summary: ScopeSummary

    var body: some View {
        switch summary {
        case .notGrantable, .none:
            Text("None")
                .foregroundStyle(.tertiary)
                .accessibilityLabel(String(localized: "No privileges"))

        case let .all(count):
            Text(String(format: String(localized: "All (%lld)"), count))

        case let .some(names, overflow, hasGrantOption):
            HStack(spacing: 4) {
                Text(overflow > 0
                    ? String(
                        format: String(localized: "%1$@ +%2$lld"),
                        names.joined(separator: ", "),
                        overflow
                    )
                    : names.joined(separator: ", "))
                    .lineLimit(1)
                if hasGrantOption {
                    Image(systemName: "arrow.up.forward.square")
                        .foregroundStyle(.secondary)
                        .help(String(localized: "Can grant these privileges to others."))
                }
            }

        case let .descendantsOnly(count):
            Label(
                String(format: String(localized: "%lld inside"), count),
                systemImage: "arrow.turn.down.right"
            )
            .foregroundStyle(.secondary)

        case let .browsingRestricted(direct):
            Text(direct.isEmpty
                ? String(localized: "Not visible")
                : direct.joined(separator: ", "))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}
