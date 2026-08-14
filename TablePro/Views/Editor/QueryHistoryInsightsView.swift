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
            await reload()
        }
        .onReceive(AppEvents.shared.queryHistoryDidUpdate) { updatedConnectionId in
            guard updatedConnectionId == nil || updatedConnectionId == connectionId else {
                return
            }
            Task { await reload() }
        }
        .accessibilityIdentifier("query-history-insights-view")
    }

    @State private var snapshot = QueryHistoryInsightSnapshot.empty
    @State private var selection: QueryHistoryInsightSelection?
    @State private var hasLoaded = false
    @State private var loadGeneration = UUID()
    @State private var loadedConnectionId: UUID?
    @FocusedValue(\.commandActions) private var actions

    @MainActor
    private func reload() async {
        let generation = UUID()
        loadGeneration = generation
        if loadedConnectionId != connectionId {
            snapshot = .empty
            selection = nil
            hasLoaded = false
            loadedConnectionId = connectionId
        }
        let loadedSnapshot = await QueryHistoryManager.shared.fetchInsights(connectionId: connectionId)
        guard !Task.isCancelled, loadGeneration == generation else {
            return
        }

        snapshot = loadedSnapshot
        hasLoaded = true
        if let selection {
            self.selection = QueryHistoryInsightSelection.refreshed(selection, in: loadedSnapshot)
        }
    }
}

enum QueryHistoryInsightCategory: Hashable {
    case mostRun
    case slowest
    case regression
}

struct QueryHistoryInsightSelection: Hashable {
    let category: QueryHistoryInsightCategory
    let insight: QueryHistoryInsight

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.category == rhs.category && lhs.insight.id == rhs.insight.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(category)
        hasher.combine(insight.id)
    }

    static func refreshed(_ selection: Self, in snapshot: QueryHistoryInsightSnapshot) -> Self? {
        all(in: snapshot).first { $0 == selection }
    }

    private static func all(in snapshot: QueryHistoryInsightSnapshot) -> [Self] {
        snapshot.mostRun.map { Self(category: .mostRun, insight: $0) }
            + snapshot.slowest.map { Self(category: .slowest, insight: $0) }
            + snapshot.regressions.map { Self(category: .regression, insight: $0) }
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
        if let selection {
            VStack(spacing: 0) {
                HighlightedSQLTextView(
                    sql: selection.insight.query.hasSuffix(";")
                        ? selection.insight.query
                        : selection.insight.query + ";",
                    databaseType: selection.insight.query.trimmingCharacters(in: .whitespaces)
                        .hasPrefix("db.") ? .mongodb : .mysql
                )
                .background(Color(nsColor: ThemeEngine.shared.colors.editor.background))

                Divider()

                QueryHistoryInsightMetadata(selection: selection)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)

                Divider()

                HStack {
                    Button(String(localized: "Copy Query")) {
                        ClipboardService.shared.writeText(selection.insight.query)
                    }
                    .controlSize(.small)

                    Spacer()

                    Button(String(localized: "Load in Editor")) {
                        loadInEditor(selection.insight.query)
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
    let selection: QueryHistoryInsightSelection

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(selection.insight.databaseName)
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
        switch selection.category {
        case .mostRun:
            guard selection.insight.successfulExecutionCount > 0 else {
                return String(
                    format: String(localized: "%@, no successful runs"),
                    QueryHistoryInsightFormatting.runCount(selection.insight.executionCount)
                )
            }
            return String(
                format: String(localized: "%@, %@ average"),
                QueryHistoryInsightFormatting.runCount(selection.insight.executionCount),
                QueryHistoryInsightFormatting.duration(selection.insight.averageExecutionTime)
            )
        case .slowest:
            return String(
                format: String(localized: "%@ average, %@ maximum"),
                QueryHistoryInsightFormatting.duration(selection.insight.averageExecutionTime),
                QueryHistoryInsightFormatting.duration(selection.insight.maximumExecutionTime)
            )
        case .regression:
            return String(
                format: String(localized: "%@ recent, %@ previous"),
                QueryHistoryInsightFormatting.duration(selection.insight.recentAverageExecutionTime),
                QueryHistoryInsightFormatting.duration(selection.insight.previousAverageExecutionTime)
            )
        }
    }

    private var secondaryMetric: String {
        switch selection.category {
        case .mostRun, .slowest:
            let executedAt = selection.insight.lastExecutedAt.formatted(date: .abbreviated, time: .shortened)
            return String(format: String(localized: "Last run: %@"), executedAt)
        case .regression:
            return String(
                format: String(localized: "%@ recent, %@ previous"),
                QueryHistoryInsightFormatting.runCount(selection.insight.recentExecutionCount),
                QueryHistoryInsightFormatting.runCount(selection.insight.previousExecutionCount)
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
