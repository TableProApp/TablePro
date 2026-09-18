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
                    elapsedText(context.state, isStale: context.isStale)
                        .font(.title3.monospacedDigit())
                        .foregroundStyle(isLive(context) ? .primary : .secondary)
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
                        Text(statusText(context))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                Image(systemName: "terminal.fill")
                    .foregroundStyle(.tint)
            } compactTrailing: {
                compactStatus(context)
            } minimal: {
                compactStatus(context)
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
                elapsedText(context.state, isStale: context.isStale)
                    .font(.body.monospacedDigit())
                Text(statusText(context))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Compact / Minimal Status

    @ViewBuilder
    private func compactStatus(_ context: ActivityViewContext<QueryActivityAttributes>) -> some View {
        if isLive(context) {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.mini)
        } else {
            Image(systemName: symbolName(for: outcome(context)))
                .foregroundStyle(tint(for: outcome(context)))
        }
    }

    // MARK: - Helpers

    private func isLive(_ context: ActivityViewContext<QueryActivityAttributes>) -> Bool {
        context.state.endedAt == nil && !context.isStale
    }

    private func outcome(_ context: ActivityViewContext<QueryActivityAttributes>) -> QueryActivityAttributes.Outcome {
        guard context.state.outcome == .running else { return context.state.outcome }
        return context.isStale ? .interrupted : .running
    }

    private func symbolName(for outcome: QueryActivityAttributes.Outcome) -> String {
        switch outcome {
        case .running: "hourglass"
        case .completed: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .stopped: "stop.circle.fill"
        case .interrupted: "exclamationmark.triangle.fill"
        }
    }

    private func tint(for outcome: QueryActivityAttributes.Outcome) -> Color {
        switch outcome {
        case .running: .secondary
        case .completed: .green
        case .failed: .red
        case .stopped: .secondary
        case .interrupted: .orange
        }
    }

    private func statusText(_ context: ActivityViewContext<QueryActivityAttributes>) -> String {
        switch outcome(context) {
        case .running:
            return context.state.rowsStreamed > 0
                ? rowCountText(context.state.rowsStreamed)
                : String(localized: "Running")
        case .completed:
            return context.state.rowsStreamed > 0
                ? rowCountText(context.state.rowsStreamed)
                : String(localized: "Done")
        case .failed:
            return String(localized: "Failed")
        case .stopped:
            return String(localized: "Stopped")
        case .interrupted:
            return String(localized: "Interrupted")
        }
    }

    @ViewBuilder
    private func elapsedText(
        _ state: QueryActivityAttributes.ContentState,
        isStale: Bool
    ) -> some View {
        if let ended = state.endedAt {
            Text(formatElapsed(ended.timeIntervalSince(state.startedAt)))
        } else if isStale {
            Text(formatElapsed(state.elapsedWhenLastAlive))
        } else {
            Text(timerInterval: state.startedAt...Date.distantFuture, countsDown: false, showsHours: false)
        }
    }

    private func deepLink(connectionId: UUID) -> URL? {
        URL(string: "tablepro://connect/\(connectionId.uuidString)")
    }

    private func rowCountText(_ count: Int) -> String {
        if count == 1 {
            return String(localized: "1 row")
        }
        return String(format: String(localized: "%lld rows"), Int64(count))
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
