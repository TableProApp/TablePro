import SwiftUI

struct QueryInsightsToolbar: View {
    @Bindable var viewModel: QueryInsightsViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                scopePicker
                sourceMenu
                datePicker

                Spacer(minLength: 8)

                if viewModel.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(String(localized: "Refreshing"))
                } else if let date = viewModel.lastRefreshDate {
                    Text(date, style: .time)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .accessibilityLabel(String(localized: "Last updated"))
                }

                refreshButton
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var scopePicker: some View {
        Picker(String(localized: "Scope"), selection: $viewModel.showsAllConnections) {
            Text("This Connection").tag(false)
            Text("All Connections").tag(true)
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(width: 150)
        .accessibilityIdentifier("query-insights-scope-picker")
    }

    private var datePicker: some View {
        Picker(String(localized: "Date Range"), selection: $viewModel.dateRange) {
            ForEach(HistoryDateRange.allCases) { range in
                Text(range.title).tag(range)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(width: 130)
        .accessibilityIdentifier("query-insights-date-picker")
    }

    private var sourceMenu: some View {
        Menu {
            ForEach(QueryHistorySource.allCases) { source in
                Toggle(source.displayName, isOn: binding(for: source))
            }
            Divider()
            Button(String(localized: "My Queries Only")) {
                viewModel.sources = QueryHistorySource.userAuthored
            }
            Button(String(localized: "Everything")) {
                viewModel.sources = Set(QueryHistorySource.allCases)
            }
        } label: {
            Label(sourceSummary, systemImage: "line.3.horizontal.decrease.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityIdentifier("query-insights-source-filter")
    }

    private var sourceSummary: String {
        if viewModel.sources == QueryHistorySource.userAuthored {
            return String(localized: "My Queries")
        }
        if viewModel.sources.count == QueryHistorySource.allCases.count {
            return String(localized: "Everything")
        }
        return String(
            format: String(localized: "%lld sources", comment: "Count of selected query history sources"),
            viewModel.sources.count
        )
    }

    private var refreshButton: some View {
        Button {
            Task { await viewModel.reload() }
        } label: {
            Label(String(localized: "Refresh"), systemImage: "arrow.clockwise")
        }
        .labelStyle(.iconOnly)
        .disabled(viewModel.isRefreshing)
        .help(String(localized: "Refresh"))
        .accessibilityIdentifier("query-insights-refresh-button")
    }

    /// A source the user turns off is a source they do not want counted, but an empty set would
    /// filter every panel to nothing, so the last one on stays on.
    private func binding(for source: QueryHistorySource) -> Binding<Bool> {
        Binding(
            get: { viewModel.sources.contains(source) },
            set: { isOn in
                var updated = viewModel.sources
                if isOn {
                    updated.insert(source)
                } else {
                    updated.remove(source)
                }
                guard !updated.isEmpty else { return }
                viewModel.sources = updated
            }
        )
    }
}
