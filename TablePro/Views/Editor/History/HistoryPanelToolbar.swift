import SwiftUI

struct HistoryPanelToolbar: View {
    let viewModel: HistoryPanelViewModel
    @Bindable var state: HistoryPanelState

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                scopePicker
                sourceMenu
                datePicker
                outcomePicker

                Spacer(minLength: 8)

                NativeSearchField(
                    text: $state.searchText,
                    placeholder: String(localized: "Search"),
                    controlSize: .small,
                    maxWidth: 220,
                    accessibilityIdentifier: "query-history-search-field"
                )

                pauseButton
                clearButton
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            if state.isCapturePaused {
                pausedBanner
            }

            Divider()
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onChange(of: state.searchText) {
            viewModel.scheduleSearchReload()
        }
        .onChange(of: state.showsAllConnections) { reload() }
        .onChange(of: state.dateRange) { reload() }
        .onChange(of: state.outcome) { reload() }
        .onChange(of: state.sources) { reload() }
    }

    private var scopePicker: some View {
        Picker(String(localized: "Scope"), selection: $state.showsAllConnections) {
            Text("This Connection").tag(false)
            Text("All Connections").tag(true)
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(width: 150)
        .accessibilityIdentifier("query-history-scope-picker")
    }

    private var datePicker: some View {
        Picker(String(localized: "Date Range"), selection: $state.dateRange) {
            ForEach(HistoryDateRange.allCases) { range in
                Text(range.title).tag(range)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(width: 130)
        .accessibilityIdentifier("query-history-date-picker")
    }

    private var outcomePicker: some View {
        Picker(String(localized: "Outcome"), selection: $state.outcome) {
            ForEach(QueryHistoryOutcome.allCases, id: \.self) { outcome in
                Text(outcome.displayName).tag(outcome)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(width: 130)
        .accessibilityIdentifier("query-history-outcome-picker")
    }

    private var sourceMenu: some View {
        Menu {
            ForEach(QueryHistorySource.allCases) { source in
                Toggle(source.displayName, isOn: binding(for: source))
            }
            Divider()
            Button(String(localized: "My Queries Only")) {
                state.sources = QueryHistorySource.userAuthored
            }
            Button(String(localized: "Everything")) {
                state.sources = Set(QueryHistorySource.allCases)
            }
        } label: {
            Label(sourceSummary, systemImage: "line.3.horizontal.decrease.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityIdentifier("query-history-source-filter")
    }

    private var sourceSummary: String {
        if state.sources == QueryHistorySource.userAuthored {
            return String(localized: "My Queries")
        }
        if state.sources.count == QueryHistorySource.allCases.count {
            return String(localized: "Everything")
        }
        return String(
            format: String(localized: "%lld sources", comment: "Count of selected query history sources"),
            state.sources.count
        )
    }

    private func binding(for source: QueryHistorySource) -> Binding<Bool> {
        Binding(
            get: { state.sources.contains(source) },
            set: { isOn in
                var updated = state.sources
                if isOn {
                    updated.insert(source)
                } else {
                    updated.remove(source)
                }
                guard !updated.isEmpty else { return }
                state.sources = updated
            }
        )
    }

    private var pauseButton: some View {
        Button {
            state.isCapturePaused.toggle()
        } label: {
            Image(systemName: state.isCapturePaused ? "play.circle" : "pause.circle")
        }
        .buttonStyle(.borderless)
        .help(
            state.isCapturePaused
                ? String(localized: "Start recording queries again")
                : String(localized: "Stop recording queries on this Mac")
        )
        .accessibilityLabel(
            state.isCapturePaused
                ? String(localized: "Resume Query History")
                : String(localized: "Pause Query History")
        )
        .accessibilityIdentifier("query-history-pause")
    }

    private var pausedBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "pause.circle.fill")
                .foregroundStyle(.secondary)
            Text("Not recording new queries on this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button(String(localized: "Resume")) {
                state.isCapturePaused = false
            }
            .buttonStyle(.link)
            .font(.caption)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .accessibilityIdentifier("query-history-paused-banner")
    }

    private var clearButton: some View {
        Button {
            confirmClear()
        } label: {
            Image(systemName: "trash")
        }
        .buttonStyle(.borderless)
        .disabled(viewModel.isEmpty)
        .help(String(localized: "Clear the queries shown here"))
        .accessibilityLabel(String(localized: "Clear History"))
        .accessibilityIdentifier("query-history-clear")
    }

    private func confirmClear() {
        Task { @MainActor in
            let confirmed = await AlertHelper.confirmDestructive(
                title: String(localized: "Clear Query History?"),
                message: clearMessage,
                confirmButton: String(localized: "Clear"),
                cancelButton: String(localized: "Cancel")
            )
            guard confirmed else { return }
            await viewModel.clearVisibleScope()
        }
    }

    private var clearMessage: String {
        HistoryClearSummary.message(
            showsAllConnections: state.showsAllConnections,
            sources: state.sources,
            outcome: state.outcome,
            dateRange: state.dateRange,
            searchText: state.searchText
        )
    }

    private func reload() {
        Task { await viewModel.reload() }
    }
}
