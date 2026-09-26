//
//  ExecutionIndicatorView.swift
//  TablePro
//

import SwiftUI
import TableProPluginKit

/// What the query is doing, in the bar under the result it produces.
///
/// It used to sit in the centred toolbar item, where it reported the window rather than the tab and
/// where AppKit dropped it whole as soon as the window narrowed. Every comparable client puts this
/// in a bottom bar, and so does the rest of what this bar already reports.
struct ExecutionIndicatorView: View {
    @ObservedObject private var settingsManager = AppSettingsManager.shared
    /// Held back rather than the spinner inside it, so a query too fast to report leaves the
    /// previous duration standing instead of emptying the readout and changing its width twice.
    /// Clicking a table on a local database runs in single-digit milliseconds, and "Executing…"
    /// appearing and going in that time is churn the user reads as a flicker.
    ///
    /// The Stop button goes with it. Nothing needs cancelling inside the grace, and past it the
    /// button is there, which is what the HIG asks: "When it's feasible, let people halt
    /// processing."
    let report: ExecutionSlot.Report
    let isExecuting: Bool
    /// Defaulted so a preview and a caller with nothing to protect read the same as before. A batch
    /// whose commit is on the wire passes false: the spinner stays and the button dims, rather than
    /// offering a cancel that cannot reach the server.
    var canStop = true
    var onCancel: (() -> Void)?

    @State private var showsBreakdown = false

    /// Why the two numbers differ, in the popover's own words. A client-measured first row carries
    /// one network round trip and a server-reported figure does not, and a reader comparing them
    /// has no other way to know that.
    private static let clientExplanation = String(localized: """
        Time to the first row is measured here, so it includes one network round trip.
        """)

    private static let serverExplanation = String(localized: """
        The server figure is the engine's own report, so it excludes network time.
        """)

    /// Resolved from the user's own binding rather than written into the string. A hint naming a
    /// key nobody bound is the same defect as a toolbar tooltip that outlived a rebind (#2185).
    private var cancelHint: String {
        settingsManager.keyboard.shortcutHint(String(localized: "Cancel Query"), for: .cancelQuery)
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

    // MARK: - Readout

    /// The elapsed number stays the label, because that is what a reader already knows how to read.
    /// The split lives one click away rather than widening the bar with a second figure whose
    /// meaning nothing on screen explains.
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

// MARK: - Preview

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
