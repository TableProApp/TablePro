import ActivityKit
import SwiftUI
import WidgetKit

struct QueryLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: QueryActivityAttributes.self) { context in
            lockScreenView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.7))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "terminal.fill")
                        .foregroundStyle(.tint)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    elapsedText(context.state)
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.connectionName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(context.attributes.queryPreview)
                            .font(.system(.footnote, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer()
                        if context.state.rowsStreamed > 0 {
                            Label("\(context.state.rowsStreamed)", systemImage: "list.bullet")
                                .font(.caption)
                                .labelStyle(.titleAndIcon)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: "terminal.fill")
            } compactTrailing: {
                elapsedText(context.state)
                    .monospacedDigit()
            } minimal: {
                Image(systemName: "terminal.fill")
            }
        }
    }

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
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(context.attributes.queryPreview)
                    .font(.system(.subheadline, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                elapsedText(context.state)
                    .font(.body.monospacedDigit())
                if context.state.rowsStreamed > 0 {
                    Text("\(context.state.rowsStreamed) rows")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func elapsedText(_ state: QueryActivityAttributes.ContentState) -> some View {
        if let ended = state.endedAt {
            Text(formatElapsed(ended.timeIntervalSince(state.startedAt)))
        } else {
            // System ticks this label every second without app push updates.
            Text(timerInterval: state.startedAt...Date.distantFuture, countsDown: false, showsHours: false)
        }
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
