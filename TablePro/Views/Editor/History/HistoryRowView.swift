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

                /// Spacing alone separates the three facts, the way the inspector's status bar
                /// separates its counts. A middle dot between them is punctuation the rest of the
                /// app's chrome no longer uses, and each fact already reads as its own phrase.
                HStack(spacing: 12) {
                    if let connectionLabel {
                        Label {
                            Text(connectionLabel.name)
                        } icon: {
                            connectionGlyph(connectionLabel.color?.color)
                        }
                        .labelStyle(.titleAndIcon)
                    }

                    Text(entry.databaseDisplayName)
                        .truncationMode(.middle)

                    if entry.source != .editor {
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

    /// The glyph the toolbar's own connection control falls back to, tinted with the connection's
    /// colour. It replaces a filled dot, which carried the colour and nothing else, so a connection
    /// with no colour of its own drew a grey dot that named nothing.
    ///
    /// Not the engine's own icon, which is the obvious candidate and does not survive this size:
    /// half of them are asset-catalog line art, and measured at 12pt against the emphasized
    /// selection fill the PostgreSQL elephant kept no pixel of the tint at all.
    ///
    /// A connection's colour is a fixed value, so it disappears into that fill unless it switches
    /// with the background. The uncoloured case is secondary content and adapts by itself.
    @ViewBuilder
    private func connectionGlyph(_ color: Color?) -> some View {
        let glyph = Image(systemName: "network")
        if let color {
            glyph.selectionAwareTint(color)
        } else {
            glyph.foregroundStyle(Color.secondary)
        }
    }
}
