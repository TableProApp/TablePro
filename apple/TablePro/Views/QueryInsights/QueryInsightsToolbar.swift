import SwiftUI

struct QueryInsightsToolbar: View {
    @ObservedObject var viewModel: QueryInsightsViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                scopePicker
                sourceMenu
                datePicker

                Spacer(minLength: 8)

                PaneRefreshControls(
                    isRefreshing: viewModel.isRefreshing,
                    lastRefreshDate: viewModel.lastRefreshDate,
                    accessibilityIdentifier: "query-insights-refresh-button"
                ) {
                    Task { await viewModel.reload() }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()
        }
        .paneBarBackground()
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
        .menuStyle(.button)
        .buttonStyle(.borderless)
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

    // The last source on stays on: an empty set would filter every panel to nothing.
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
