import SwiftUI

struct HistoryRowView: View {
    let entry: QueryHistoryEntry
    let connectionLabel: HistoryConnectionLabel?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: entry.wasSuccessful ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(entry.wasSuccessful ? Color.secondary : Color.red)
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
                            Image(systemName: "circle.fill")
                                .font(.system(size: 6))
                                .foregroundStyle(connectionLabel.color?.color ?? .secondary)
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
}
