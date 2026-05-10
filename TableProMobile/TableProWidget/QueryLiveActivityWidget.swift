import ActivityKit
import SwiftUI
import WidgetKit

struct QueryLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: QueryActivityAttributes.self) { context in
            lockScreenView(context: context)
                .widgetURL(deepLink(connectionId: context.attributes.connectionId))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "terminal.fill")
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .frame(width: 32, height: 32)
                        .background(.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 7))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    elapsedText(context.state)
                        .font(.title3.monospacedDigit())
                        .foregroundStyle(context.state.endedAt == nil ? .primary : .secondary)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.connectionName)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(context.attributes.queryPreview)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer()
                        if context.state.rowsStreamed > 0 {
                            Label("^[\(context.state.rowsStreamed) row](inflect: true)", systemImage: "list.bullet")
                                .font(.caption)
                                .labelStyle(.titleAndIcon)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: "terminal.fill")
                    .foregroundStyle(.tint)
            } compactTrailing: {
                compactStatus(state: context.state)
            } minimal: {
                compactStatus(state: context.state)
            }
            .widgetURL(deepLink(connectionId: context.attributes.connectionId))
        }
    }

    // MARK: - Lock Screen

    @ViewBuilder
    private func lockScreenView(context: ActivityViewContext<QueryActivityAttributes>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "terminal.fill")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 36, height: 36)
                .background(.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(context.attributes.connectionName)
                    .font(.subheadline.weight(.medium))
                Text(context.attributes.queryPreview)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                elapsedText(context.state)
                    .font(.body.monospacedDigit())
                if context.state.rowsStreamed > 0 {
                    Text("^[\(context.state.rowsStreamed) row](inflect: true)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Compact / Minimal Status

    @ViewBuilder
    private func compactStatus(state: QueryActivityAttributes.ContentState) -> some View {
        if state.endedAt != nil {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.mini)
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func elapsedText(_ state: QueryActivityAttributes.ContentState) -> some View {
        if let ended = state.endedAt {
            Text(formatElapsed(ended.timeIntervalSince(state.startedAt)))
        } else {
            Text(timerInterval: state.startedAt...Date.distantFuture, countsDown: false, showsHours: false)
        }
    }

    private func deepLink(connectionId: UUID) -> URL? {
        URL(string: "tablepro://connect/\(connectionId.uuidString)")
    }

    private func formatElapsed(_ seconds: TimeInterval) -> String {
        if seconds < 60 {
            return String(format: "%.1fs", seconds)
        }
        let minutes = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", minutes, secs)
    }
}
