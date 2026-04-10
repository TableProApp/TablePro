import SwiftUI

struct DashboardToolbarView: View {
    @Bindable var viewModel: ServerDashboardViewModel

    var body: some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(DashboardRefreshInterval.allCases) { interval in
                    Button {
                        viewModel.refreshInterval = interval
                    } label: {
                        HStack {
                            Text(interval.displayLabel)
                            if viewModel.refreshInterval == interval {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Label(viewModel.refreshInterval.displayLabel, systemImage: "arrow.clockwise")
                    .monospacedDigit()
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button {
                viewModel.isPaused.toggle()
            } label: {
                Image(systemName: viewModel.isPaused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(.borderless)
            .help(viewModel.isPaused ? String(localized: "Resume") : String(localized: "Pause"))
            .disabled(viewModel.refreshInterval == .off)

            Button {
                Task { await viewModel.refreshNow() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Refresh Now"))
            .disabled(viewModel.isRefreshing)
            .keyboardShortcut("r", modifiers: .command)

            Spacer()

            if viewModel.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            }

            if let date = viewModel.lastRefreshDate {
                Text(date, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Text(viewModel.databaseType.rawValue)
                .font(.caption)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
