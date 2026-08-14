import SwiftUI

struct QueryHistoryInsightsView: View {
    let connectionId: UUID

    var body: some View {
        QueryHistoryInsightsPanel(
            snapshot: snapshot,
            selection: $selection,
            hasLoaded: hasLoaded,
            loadInEditor: { actions?.loadQueryIntoEditor($0) }
        )
        .requiresPro(.queryHistoryInsights)
        .task(id: connectionId) {
            pendingReload?.cancel()
            if loadedConnectionId != connectionId {
                snapshot = .empty
                selection = nil
                hasLoaded = false
                loadedConnectionId = connectionId
            }
            await load()
        }
        .onReceive(AppEvents.shared.queryHistoryDidUpdate) { updatedConnectionId in
            guard updatedConnectionId == nil || updatedConnectionId == connectionId else {
                return
            }
            scheduleReload()
        }
        .onDisappear {
            pendingReload?.cancel()
        }
        .accessibilityIdentifier("query-history-insights-view")
    }

    private static let reloadCoalescingDelay = Duration.milliseconds(250)

    @State private var snapshot = QueryHistoryInsightSnapshot.empty
    @State private var selection: QueryHistoryInsightSelection?
    @State private var hasLoaded = false
    @State private var loadedConnectionId: UUID?
    @State private var pendingReload: Task<Void, Never>?
    @FocusedValue(\.commandActions) private var actions

    @MainActor
    private func scheduleReload() {
        pendingReload?.cancel()
        pendingReload = Task { @MainActor in
            try? await Task.sleep(for: Self.reloadCoalescingDelay)
            guard !Task.isCancelled else { return }
            await load()
        }
    }

    @MainActor
    private func load() async {
        let loadedSnapshot = await QueryHistoryManager.shared.fetchInsights(connectionId: connectionId)
        guard !Task.isCancelled, loadedConnectionId == connectionId else {
            return
        }

        snapshot = loadedSnapshot
        hasLoaded = true
        if let selection, loadedSnapshot.insight(for: selection) == nil {
            self.selection = nil
        }
    }
}

private struct QueryHistoryInsightsPanel: View {
    let snapshot: QueryHistoryInsightSnapshot
    @Binding var selection: QueryHistoryInsightSelection?

    let hasLoaded: Bool
    let loadInEditor: (String) -> Void

    var body: some View {
        if !hasLoaded {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if snapshot.isEmpty {
            ContentUnavailableView(
                String(localized: "No Query Insights Yet"),
                systemImage: "chart.line.uptrend.xyaxis",
                description: Text(String(localized: "Run queries on this connection to build local insights."))
            )
        } else {
            HSplitView {
                insightList
                    .frame(minWidth: 260, idealWidth: 320)

                insightDetail
                    .frame(minWidth: 300)
            }
        }
    }

    private var insightList: some View {
        List(selection: $selection) {
            insightSection(
                title: String(localized: "Most Run"),
                emptyMessage: String(localized: "No queries recorded."),
                category: .mostRun,
                insights: snapshot.mostRun
            )
            insightSection(
                title: String(localized: "Slowest"),
                emptyMessage: String(localized: "No successful queries recorded."),
                category: .slowest,
                insights: snapshot.slowest
            )
            insightSection(
                title: String(localized: "Slower Than Last Week"),
                emptyMessage: String(localized: "No meaningful regressions detected."),
                category: .regression,
                insights: snapshot.regressions
            )
        }
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, 48)
        .accessibilityIdentifier("query-history-insights-list")
    }

    @ViewBuilder
    private var insightDetail: some View {
        if let selection, let insight = snapshot.insight(for: selection) {
            VStack(spacing: 0) {
                HighlightedSQLTextView(
                    sql: insight.query.hasSuffix(";")
                        ? insight.query
                        : insight.query + ";",
                    databaseType: insight.query.trimmingCharacters(in: .whitespaces)
                        .hasPrefix("db.") ? .mongodb : .mysql
                )
                .background(Color(nsColor: ThemeEngine.shared.colors.editor.background))

                Divider()

                QueryHistoryInsightMetadata(category: selection.category, insight: insight)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)

                Divider()

                HStack {
                    Button(String(localized: "Copy Query")) {
                        ClipboardService.shared.writeText(insight.query)
                    }
                    .controlSize(.small)

                    Spacer()

                    Button(String(localized: "Load in Editor")) {
                        loadInEditor(insight.query)
                    }
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
                }
                .padding(12)
            }
        } else {
            ContentUnavailableView(
                String(localized: "Select an Insight"),
                systemImage: "chart.line.uptrend.xyaxis",
                description: Text(String(localized: "Choose a query to inspect its execution history."))
            )
        }
    }

    private func insightSection(
        title: String,
        emptyMessage: String,
        category: QueryHistoryInsightCategory,
        insights: [QueryHistoryInsight]
    ) -> some View {
        Section(title) {
            if insights.isEmpty {
                Text(emptyMessage)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(insights) { insight in
                    QueryHistoryInsightRow(category: category, insight: insight)
                        .tag(QueryHistoryInsightSelection(category: category, insight: insight))
                }
            }
        }
    }
}

private struct QueryHistoryInsightRow: View {
    let category: QueryHistoryInsightCategory
    let insight: QueryHistoryInsight

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(insight.query)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)

            HStack(spacing: 8) {
                Text(insight.databaseName)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text(metric)
                    .monospacedDigit()
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private var metric: String {
        switch category {
        case .mostRun:
            QueryHistoryInsightFormatting.runCount(insight.executionCount)
        case .slowest:
            QueryHistoryInsightFormatting.duration(insight.averageExecutionTime)
        case .regression:
            String(format: String(localized: "+%d%%"), insight.slowdownPercentage)
        }
    }
}

private struct QueryHistoryInsightMetadata: View {
    let category: QueryHistoryInsightCategory
    let insight: QueryHistoryInsight

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(insight.databaseName)
                .font(.subheadline.weight(.medium))

            Text(primaryMetric)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text(secondaryMetric)
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
    }

    private var primaryMetric: String {
        switch category {
        case .mostRun:
            guard insight.successfulExecutionCount > 0 else {
                return String(
                    format: String(localized: "%@, no successful runs"),
                    QueryHistoryInsightFormatting.runCount(insight.executionCount)
                )
            }
            return String(
                format: String(localized: "%@, %@ average"),
                QueryHistoryInsightFormatting.runCount(insight.executionCount),
                QueryHistoryInsightFormatting.duration(insight.averageExecutionTime)
            )
        case .slowest:
            return String(
                format: String(localized: "%@ average, %@ maximum"),
                QueryHistoryInsightFormatting.duration(insight.averageExecutionTime),
                QueryHistoryInsightFormatting.duration(insight.maximumExecutionTime)
            )
        case .regression:
            return String(
                format: String(localized: "%@ recent, %@ previous"),
                QueryHistoryInsightFormatting.duration(insight.recentAverageExecutionTime),
                QueryHistoryInsightFormatting.duration(insight.previousAverageExecutionTime)
            )
        }
    }

    private var secondaryMetric: String {
        switch category {
        case .mostRun, .slowest:
            let executedAt = insight.lastExecutedAt.formatted(date: .abbreviated, time: .shortened)
            return String(format: String(localized: "Last run: %@"), executedAt)
        case .regression:
            return String(
                format: String(localized: "%@ recent, %@ previous"),
                QueryHistoryInsightFormatting.runCount(insight.recentExecutionCount),
                QueryHistoryInsightFormatting.runCount(insight.previousExecutionCount)
            )
        }
    }
}

private enum QueryHistoryInsightFormatting {
    static func duration(_ duration: TimeInterval) -> String {
        if duration < 1 {
            return String(format: String(localized: "%.0f ms"), duration * 1_000)
        }
        return String(format: String(localized: "%.2f s"), duration)
    }

    static func runCount(_ count: Int) -> String {
        if count == 1 {
            return String(localized: "1 run")
        }
        return String(format: String(localized: "%d runs"), count)
    }
}

#if DEBUG
private struct QueryHistoryInsightsViewPreview: View {
    init() {
        let connectionId = UUID()
        let frequent = QueryHistoryInsight(
            connectionId: connectionId,
            databaseName: "analytics",
            query: "SELECT country, COUNT(*) FROM customers GROUP BY country",
            executionCount: 42,
            successfulExecutionCount: 42,
            averageExecutionTime: 0.18,
            maximumExecutionTime: 0.42,
            lastExecutedAt: Date(),
            recentExecutionCount: 8,
            recentAverageExecutionTime: 0.18,
            previousExecutionCount: 7,
            previousAverageExecutionTime: 0.16
        )
        let regression = QueryHistoryInsight(
            connectionId: connectionId,
            databaseName: "analytics",
            query: "SELECT * FROM events WHERE created_at >= CURRENT_DATE - INTERVAL '30 days'",
            executionCount: 18,
            successfulExecutionCount: 18,
            averageExecutionTime: 1.84,
            maximumExecutionTime: 3.12,
            lastExecutedAt: Date(),
            recentExecutionCount: 9,
            recentAverageExecutionTime: 2.4,
            previousExecutionCount: 9,
            previousAverageExecutionTime: 1.28
        )
        let snapshot = QueryHistoryInsightSnapshot(
            mostRun: [frequent, regression],
            slowest: [regression, frequent],
            regressions: [regression]
        )
        self.snapshot = snapshot
        _selection = State(
            initialValue: QueryHistoryInsightSelection(category: .regression, insight: regression)
        )
    }

    var body: some View {
        QueryHistoryInsightsPanel(
            snapshot: snapshot,
            selection: $selection,
            hasLoaded: true,
            loadInEditor: { _ in }
        )
        .frame(width: 760, height: 440)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.controlActiveState, .active)
    }

    @State private var selection: QueryHistoryInsightSelection?

    private let snapshot: QueryHistoryInsightSnapshot
}

#Preview {
    QueryHistoryInsightsViewPreview()
}
#endif
