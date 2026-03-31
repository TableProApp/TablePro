//
//  ExecutionIndicatorView.swift
//  TablePro
//
//  Query execution state indicator for the toolbar.
//  Shows a spinner during execution and optionally displays duration.
//

import SwiftUI

/// Compact execution indicator for the toolbar right section
struct ExecutionIndicatorView: View {
    let isExecuting: Bool
    let lastDuration: TimeInterval?
    let clickHouseProgress: ClickHouseQueryProgress?
    let lastClickHouseProgress: ClickHouseQueryProgress?

    var body: some View {
        HStack(spacing: 5) {
            if isExecuting {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(String(localized: "Query executing"))
                if let progress = clickHouseProgress {
                    Text(progress.formattedLive)
                        .font(.system(size: ThemeEngine.shared.activeTheme.typography.small, weight: .regular, design: .monospaced))
                        .foregroundStyle(ThemeEngine.shared.colors.toolbar.tertiaryTextSwiftUI)
                } else {
                    Text("Executing...")
                        .font(.system(size: ThemeEngine.shared.activeTheme.typography.small, weight: .regular, design: .monospaced))
                        .foregroundStyle(ThemeEngine.shared.colors.toolbar.tertiaryTextSwiftUI)
                }
            } else if let chProgress = lastClickHouseProgress {
                Text(chProgress.formattedSummary)
                    .font(.system(size: ThemeEngine.shared.activeTheme.typography.small, weight: .regular, design: .monospaced))
                    .foregroundStyle(ThemeEngine.shared.colors.toolbar.tertiaryTextSwiftUI)
                    .accessibilityLabel(String(localized: "Last query: \(chProgress.formattedSummary)"))
                    .help("Last query execution summary")
            } else if let duration = lastDuration {
                Text(formattedDuration(duration))
                    .font(.system(size: ThemeEngine.shared.activeTheme.typography.small, weight: .regular, design: .monospaced))
                    .foregroundStyle(ThemeEngine.shared.colors.toolbar.tertiaryTextSwiftUI)
                    .accessibilityLabel(
                        String(localized: "Last query took \(formattedDuration(duration))")
                    )
                    .help("Last query execution time")
            } else {
                Text("--")
                    .font(.system(size: ThemeEngine.shared.activeTheme.typography.small, weight: .regular, design: .monospaced))
                    .foregroundStyle(.quaternary)
                    .accessibilityLabel(String(localized: "No query executed yet"))
                    .help("Run a query to see execution time")
            }
        }
        .padding(.trailing, ThemeEngine.shared.activeTheme.spacing.xs)
    }

    // MARK: - Helpers

    /// Format duration for display
    private func formattedDuration(_ duration: TimeInterval) -> String {
        if duration < 0.001 {
            return String(localized: "<1ms")
        } else if duration < 1.0 {
            let ms = String(format: "%.0f", duration * 1_000)
            return String(localized: "\(ms)ms")
        } else if duration < 60.0 {
            let secs = String(format: "%.2f", duration)
            return String(localized: "\(secs)s")
        } else {
            let minutes = Int(duration) / 60
            let seconds = Int(duration) % 60
            return String(localized: "\(minutes)m \(seconds)s")
        }
    }
}

// MARK: - Preview

#Preview("Executing") {
    ExecutionIndicatorView(isExecuting: true, lastDuration: nil, clickHouseProgress: nil, lastClickHouseProgress: nil)
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
}

#Preview("Completed Fast") {
    ExecutionIndicatorView(isExecuting: false, lastDuration: 0.023, clickHouseProgress: nil, lastClickHouseProgress: nil)
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
}

#Preview("Completed Slow") {
    ExecutionIndicatorView(isExecuting: false, lastDuration: 2.456, clickHouseProgress: nil, lastClickHouseProgress: nil)
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
}

#Preview("No Duration") {
    ExecutionIndicatorView(isExecuting: false, lastDuration: nil, clickHouseProgress: nil, lastClickHouseProgress: nil)
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
}
