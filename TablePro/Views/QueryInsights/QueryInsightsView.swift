import SwiftUI

struct QueryInsightsView: View {
    let viewModel: QueryInsightsViewModel
    let coordinator: MainContentCoordinator

    /// `requiresPro` only disables the content and lays a scrim over it, so on its own it decides
    /// what the screen looks like and nothing about what the screen does. Activation is gated on
    /// the same answer, or an unlicensed Mac computes every aggregate, subscribes to history for
    /// the session, and leaves the numbers sitting in the view hierarchy for anything that reads it.
    private var isUnlocked: Bool {
        LicenseManager.shared.isFeatureAvailable(.queryInsights)
    }

    var body: some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                QueryInsightsToolbar(viewModel: viewModel)
            }
            .requiresPro(.queryInsights)
            .task(id: isUnlocked) {
                guard isUnlocked else { return }
                await viewModel.activate()
            }
            .onDisappear {
                viewModel.deactivate()
            }
    }

    @ViewBuilder
    private var content: some View {
        if !isUnlocked {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !viewModel.hasLoadedContent {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.isStoreUnavailable {
            ContentUnavailableView(
                String(localized: "History Unavailable"),
                systemImage: "exclamationmark.triangle",
                description: Text("The query history database could not be opened, so there is nothing to summarize.")
            )
        } else if viewModel.snapshot.isEmpty {
            emptyState
        } else {
            panels
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if viewModel.hasNarrowingFilter {
            ContentUnavailableView {
                Label(String(localized: "No Queries Match"), systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("No queries ran in this range, from the sources you selected.")
            } actions: {
                Button(String(localized: "Reset Filters")) {
                    viewModel.resetFilters()
                }
            }
        } else {
            ContentUnavailableView(
                String(localized: "No Queries Yet"),
                systemImage: "chart.bar.xaxis",
                description: Text("Run some queries and this tab will show which you run most, which run slowest, and which got slower.")
            )
        }
    }

    private var panels: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                QueryInsightsSummaryBar(totals: viewModel.snapshot.totals)

                QueryInsightsActivityChart(
                    buckets: viewModel.snapshot.activity,
                    granularity: viewModel.snapshot.granularity
                )

                QueryInsightsSection(
                    title: String(localized: "Most Run"),
                    systemImage: "arrow.trianglehead.2.clockwise",
                    isEmpty: viewModel.snapshot.mostRun.isEmpty,
                    emptyMessage: String(localized: "No queries in this range.")
                ) {
                    QueryInsightsGroupList(
                        groups: viewModel.snapshot.mostRun,
                        metric: .callCount,
                        onCopy: copy,
                        onLoadInEditor: load
                    )
                }

                QueryInsightsSection(
                    title: String(localized: "Slowest"),
                    systemImage: "tortoise",
                    accessory: AnyView(slowestRankingPicker),
                    isEmpty: viewModel.snapshot.slowest.isEmpty,
                    emptyMessage: slowestEmptyMessage
                ) {
                    QueryInsightsGroupList(
                        groups: viewModel.snapshot.slowest,
                        metric: .duration(viewModel.slowestRanking),
                        onCopy: copy,
                        onLoadInEditor: load
                    )
                }

                QueryInsightsSection(
                    title: String(localized: "Got Slower"),
                    systemImage: "chart.line.uptrend.xyaxis",
                    isEmpty: viewModel.snapshot.regressions.isEmpty,
                    emptyMessage: regressionEmptyMessage
                ) {
                    QueryInsightsRegressionList(
                        regressions: viewModel.snapshot.regressions,
                        onCopy: copyText,
                        onLoadInEditor: loadText
                    )
                }

                QueryInsightsSection(
                    title: String(localized: "Failures"),
                    systemImage: "exclamationmark.triangle",
                    isEmpty: viewModel.snapshot.failures.isEmpty,
                    emptyMessage: String(localized: "No query failed in this range.")
                ) {
                    QueryInsightsGroupList(
                        groups: viewModel.snapshot.failures,
                        metric: .failures,
                        onCopy: copy,
                        onLoadInEditor: load
                    )
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var slowestRankingPicker: some View {
        Picker(String(localized: "Rank By"), selection: Bindable(viewModel).slowestRanking) {
            ForEach(QueryInsightsSlowestRanking.allCases) { ranking in
                Text(ranking.displayName).tag(ranking)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .accessibilityIdentifier("query-insights-slowest-ranking")
    }

    /// Says which floor hid everything, because "nothing here" reads as a broken panel when the
    /// user can see in the list above that queries did run.
    private var slowestEmptyMessage: String {
        guard viewModel.slowestRanking == .averageTime else {
            return String(localized: "No queries in this range.")
        }
        return String(
            format: String(
                localized: "No query ran at least %lld times, which is the minimum for an average to mean anything.",
                comment: "Empty state for the average-time ranking, %lld is a run count"
            ),
            QueryInsightsRequest.minimumMeanRankingCalls
        )
    }

    private var regressionEmptyMessage: String {
        String(
            format: String(
                localized: """
                    Nothing got at least %1$lld%% slower than the period before. A query needs \
                    %2$lld runs in both periods, and has to have grown by at least %3$@.
                    """,
                comment: "Empty state for regressions: %1$lld is a percentage, %2$lld a run count, %3$@ a duration"
            ),
            Int((QueryInsightsRequest.regressionRatio - 1) * 100),
            QueryInsightsRequest.minimumRegressionSamples,
            QueryDurationFormatter.string(from: QueryInsightsRequest.minimumRegressionIncrease)
        )
    }

    private func copy(_ group: QueryInsightsGroup) {
        copyText(group.representativeQuery)
    }

    private func load(_ group: QueryInsightsGroup) {
        loadText(group.representativeQuery)
    }

    private func copyText(_ query: String) {
        ClipboardService.shared.writeText(query)
    }

    /// A shape can be aggregated across several connections, so there is no one connection it came
    /// from. It loads into the window the user is looking at, which is the one they can run it in.
    private func loadText(_ query: String) {
        coordinator.openQuery(
            query,
            on: coordinator.connectionId,
            databaseName: coordinator.browseDatabaseName,
            intent: .loadIntoFrontTab
        )
    }
}
