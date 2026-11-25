import SwiftUI

struct DashboardToolbarView: View {
    @ObservedObject var viewModel: ServerDashboardViewModel
    @ObservedObject private var status: DashboardRefreshStatus

    init(viewModel: ServerDashboardViewModel) {
        _viewModel = ObservedObject(wrappedValue: viewModel)
        _status = ObservedObject(wrappedValue: viewModel.refreshStatus)
    }

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
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .fixedSize()

            Button {
                viewModel.isPaused.toggle()
            } label: {
                Image(systemName: viewModel.isPaused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(.borderless)
            .help(viewModel.isPaused ? String(localized: "Resume") : String(localized: "Pause"))
            .accessibilityLabel(viewModel.isPaused ? String(localized: "Resume") : String(localized: "Pause"))
            .disabled(viewModel.refreshInterval == .off)

            Button {
                Task { await viewModel.refreshNow() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Refresh Now"))
            .accessibilityLabel(String(localized: "Refresh Now"))
            .disabled(status.isRefreshing)

            Spacer()

            if status.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            }

            if let date = status.lastRefreshDate {
                Text(date, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Text(viewModel.databaseType.rawValue)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
