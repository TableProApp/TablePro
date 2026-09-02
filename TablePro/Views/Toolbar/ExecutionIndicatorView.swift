//
//  ExecutionIndicatorView.swift
//  TablePro
//
//  Query execution state indicator for the toolbar.
//  Shows a spinner during execution and optionally displays duration.
//

import SwiftUI
import TableProPluginKit

/// Compact execution indicator for the toolbar right section
struct ExecutionIndicatorView: View {
    let isExecuting: Bool
    let lastTiming: PluginQueryTiming?
    var onCancel: (() -> Void)?

    /// Held back rather than the spinner inside it, so a query too fast to report leaves the
    /// previous duration standing instead of emptying the item and changing the toolbar's width
    /// twice. Clicking a table on a local database runs in single-digit milliseconds, and
    /// "Executing…" appearing and going in that time is churn the user reads as a flicker.
    ///
    /// The Stop button goes with it. Nothing needs cancelling inside the grace, and past it the
    /// button is there, which is what the HIG asks: "When it's feasible, let people halt
    /// processing."
    @State private var showsExecution = false
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

    var body: some View {
        HStack(spacing: 4) {
            if showsExecution {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(String(localized: "Query executing"))
                    .accessibilityIdentifier("execution-indicator")
                Text("Executing…")
                    .font(.system(.subheadline, design: .monospaced).weight(.regular))
                    .foregroundStyle(ThemeEngine.shared.colors.toolbar.tertiaryTextSwiftUI)
                Button {
                    onCancel?()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .controlSize(.small)
                .accessibilityIdentifier("execution-stop")
                .help(String(localized: "Cancel Query (⌘.)"))
            } else if let timing = lastTiming {
                durationReadout(timing)
            } else {
                Text("--")
                    .font(.system(.subheadline, design: .monospaced).weight(.regular))
                    .foregroundStyle(.quaternary)
                    .accessibilityLabel(String(localized: "No query executed yet"))
                    .help(String(localized: "Run a query to see execution time"))
            }
        }
        .onChange(of: isExecuting) { _, nowExecuting in
            if nowExecuting { showsBreakdown = false }
        }
        .loadingRevealGate(isActive: isExecuting, isRevealed: $showsExecution)
    }

    // MARK: - Readout

    /// The elapsed number stays the label, because that is what a reader already knows how to read.
    /// The split lives one click away rather than widening the toolbar with a second figure whose
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
            .popover(isPresented: $showsBreakdown, arrowEdge: .bottom) {
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
            .font(.system(.subheadline, design: .monospaced).weight(.regular))
            .foregroundStyle(ThemeEngine.shared.colors.toolbar.tertiaryTextSwiftUI)
    }
}

// MARK: - Preview

#Preview("Executing") {
    ExecutionIndicatorView(isExecuting: true, lastTiming: nil)
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
}

#Preview("Completed Fast") {
    ExecutionIndicatorView(isExecuting: false, lastTiming: PluginQueryTiming(total: 0.023))
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
}

#Preview("Split") {
    ExecutionIndicatorView(
        isExecuting: false,
        lastTiming: PluginQueryTiming(total: 3.421, firstRow: 0.012)
    )
    .padding()
    .background(Color(nsColor: .windowBackgroundColor))
}

#Preview("No Duration") {
    ExecutionIndicatorView(isExecuting: false, lastTiming: nil)
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
}
