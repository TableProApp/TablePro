import SwiftUI
import TableProPluginKit
import TableProUtilities

struct ExecutionIndicatorView: View {
    @ObservedObject private var keyboard = AppSettingsManager.shared.keyboardSlice
    // Held back as a whole, Stop included, so a query too fast to report leaves the previous duration standing.
    let report: ExecutionSlot.Report
    let isExecuting: Bool
    // False while a batch's commit is on the wire: a cancel then cannot reach the server.
    var canStop = true
    var onCancel: (() -> Void)?

    @State private var showsBreakdown = false

    // A client-measured first row includes one network round trip; a server figure does not.
    private static let clientExplanation = String(localized: """
        Time to the first row is measured here, so it includes one network round trip.
        """)

    private static let serverExplanation = String(localized: """
        The server figure is the engine's own report, so it excludes network time.
        """)

    // From the user's own binding, so the hint never names a key nobody bound (#2185).
    private var cancelHint: String {
        keyboard.value.shortcutHint(String(localized: "Cancel Query"), for: .cancelQuery)
    }

    var body: some View {
        HStack(spacing: 4) {
            switch report {
            case .running:
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(String(localized: "Query executing"))
                    .accessibilityIdentifier("execution-indicator")
                Text("Executing…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    onCancel?()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .controlSize(.small)
                .disabled(!canStop)
                .accessibilityIdentifier("execution-stop")
                .accessibilityLabel(String(localized: "Cancel Query"))
                .help(canStop ? cancelHint : String(localized: "The batch is committing and cannot be stopped."))
            case let .lastRun(timing):
                durationReadout(timing)
            }
        }
        .onChange(of: isExecuting) { nowExecuting in
            if nowExecuting { showsBreakdown = false }
        }
    }

    // The split lives one click away rather than widening the bar with a second unexplained figure.
    @ViewBuilder
    private func durationReadout(_ timing: PluginQueryTiming) -> some View {
        let text = QueryDurationFormatter.string(from: timing.total)

        if timing.hasBreakdown {
            let breakdown = QueryTimingBreakdown(timing: timing)
            Button {
                showsBreakdown.toggle()
            } label: {
                durationLabel(text)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(format: String(localized: "Last query took %@"), text))
            .accessibilityHint(String(localized: "Shows how the time was spent"))
            .accessibilityIdentifier("execution-duration")
            .help(breakdown.summary)
            .popover(isPresented: $showsBreakdown, arrowEdge: .top) {
                QueryTimingPopover(
                    breakdown: breakdown,
                    explanation: timing.server != nil ? Self.serverExplanation : Self.clientExplanation
                )
            }
        } else {
            durationLabel(text)
                .accessibilityLabel(String(format: String(localized: "Last query took %@"), text))
                .accessibilityIdentifier("execution-duration")
                .help(String(localized: "Last query execution time"))
        }
    }

    private func durationLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
    }
}

#Preview("Executing") {
    ExecutionIndicatorView(report: .running, isExecuting: true)
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
}

#Preview("Completed Fast") {
    ExecutionIndicatorView(report: .lastRun(PluginQueryTiming(total: 0.023)), isExecuting: false)
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
}

#Preview("Split") {
    ExecutionIndicatorView(
        report: .lastRun(PluginQueryTiming(total: 3.421, firstRow: 0.012)),
        isExecuting: false
    )
    .padding()
    .background(Color(nsColor: .windowBackgroundColor))
}
