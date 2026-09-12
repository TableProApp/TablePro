import SwiftUI

struct HistoryRowView: View {
    let entry: QueryHistoryEntry
    let connectionLabel: HistoryConnectionLabel?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            statusIcon
                .accessibilityLabel(
                    entry.wasSuccessful
                        ? String(localized: "Succeeded")
                        : String(localized: "Failed")
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.singleLinePreview)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)

                HStack(spacing: 6) {
                    if let connectionLabel {
                        Label {
                            Text(connectionLabel.name)
                        } icon: {
                            connectionDot(connectionLabel.color?.color)
                        }
                        .labelStyle(.titleAndIcon)
                        Text(verbatim: "·")
                    }

                    Text(entry.databaseDisplayName)
                        .truncationMode(.middle)

                    if entry.source != .editor {
                        Text(verbatim: "·")
                        Label(entry.source.displayName, systemImage: entry.source.symbolName)
                            .labelStyle(.titleAndIcon)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(entry.executedAt, format: .dateTime.hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                Text(entry.hasMeasuredDuration ? entry.formattedExecutionTime : "–")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    /// `Color.secondary` already switches to the selected-content colour on a prominent fill, so it
    /// is left alone. A fixed red does not, and stayed unreadable on the accent selection.
    @ViewBuilder
    private var statusIcon: some View {
        if entry.wasSuccessful {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.secondary)
        } else {
            Image(systemName: "exclamationmark.circle.fill")
                .selectionAwareTint(.red)
        }
    }

    /// A connection's own colour is a fixed value, so it disappears into the accent fill unless it
    /// switches with the background. The unnamed case is secondary content and adapts by itself.
    @ViewBuilder
    private func connectionDot(_ color: Color?) -> some View {
        let dot = Image(systemName: "circle.fill").font(.system(size: 6))
        if let color {
            dot.selectionAwareTint(color)
        } else {
            dot.foregroundStyle(Color.secondary)
        }
    }
}
