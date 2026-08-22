//
//  QueryPlanHistoryView.swift
//  TablePro
//
//  Compares the current EXPLAIN result with one compatible earlier capture.
//

import SwiftUI
import TableProPluginKit

enum QueryPlanHistoryComparisonPresentation: Sendable {
    case structured(QueryPlanComparison)
    case rawOnly(previous: String, current: String)

    enum Kind: Equatable {
        case structured
        case rawOnly
    }

    static func resolve(
        previousPlan: QueryPlan?,
        previousRawText: String,
        currentPlan: QueryPlan?,
        currentRawText: String
    ) -> QueryPlanHistoryComparisonPresentation {
        guard let previousPlan, let currentPlan else {
            return .rawOnly(
                previous: QueryPlanHistoryRawText.bounded(previousRawText),
                current: QueryPlanHistoryRawText.bounded(currentRawText)
            )
        }
        return .structured(QueryPlanComparison(previous: previousPlan, current: currentPlan))
    }

    var kind: Kind {
        switch self {
        case .structured: return .structured
        case .rawOnly: return .rawOnly
        }
    }
}

enum QueryPlanHistoryRawText {
    static let maximumDisplayedUTF16Length = 100_000

    static func bounded(_ text: String) -> String {
        let text = text as NSString
        guard text.length > maximumDisplayedUTF16Length else { return text as String }
        return text.substring(to: maximumDisplayedUTF16Length)
            + "\n\n… "
            + String(localized: "Output truncated for display")
    }
}

enum QueryPlanHistoryNodeChangeAccessibility {
    static func value(_ change: QueryPlanNodeChange) -> String {
        change.valueChanges
            .map(detail)
            .joined(separator: ", ")
    }

    static func detail(_ change: QueryPlanNodeValueChange) -> String {
        "\(change.name): \(change.previousValue ?? "–") → \(change.currentValue ?? "–")"
    }
}

enum QueryPlanHistoryComparisonDecision {
    static func requiresBaselineParsing(currentPlan: QueryPlan?) -> Bool {
        currentPlan != nil
    }
}

actor QueryPlanHistoryComparisonWorker {
    func resolve(
        previousRawText: String,
        formatRawValue: String,
        currentPlan: QueryPlan?,
        currentRawText: String
    ) -> QueryPlanHistoryComparisonPresentation? {
        guard !Task.isCancelled else { return nil }
        guard QueryPlanHistoryComparisonDecision.requiresBaselineParsing(currentPlan: currentPlan),
              let currentPlan
        else {
            return QueryPlanHistoryComparisonPresentation.resolve(
                previousPlan: nil,
                previousRawText: previousRawText,
                currentPlan: nil,
                currentRawText: currentRawText
            )
        }
        let format = ExplainPlanFormat(rawValue: formatRawValue)
        let previousPlan = ExplainPlanParserRegistry.plan(from: previousRawText, format: format)
        guard !Task.isCancelled else { return nil }
        return QueryPlanHistoryComparisonPresentation.resolve(
            previousPlan: previousPlan,
            previousRawText: previousRawText,
            currentPlan: currentPlan,
            currentRawText: currentRawText
        )
    }
}

struct QueryPlanHistoryView: View {
    let context: ExplainPlanHistoryContext
    let currentRawText: String
    let currentExecutionTime: TimeInterval?
    let currentPlan: QueryPlan?

    @Environment(\.dismiss) private var dismiss

    @State private var loadState: LoadState = .idle
    @State private var snapshots: [ExplainPlanHistorySnapshot] = []
    @State private var selectedBaselineID: UUID?
    @State private var comparisonPresentation: QueryPlanHistoryComparisonPresentation?
    @State private var historyReloadVersion = 0
    @State private var comparisonWorker = QueryPlanHistoryComparisonWorker()

    private enum LoadState {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    private var selectedBaseline: ExplainPlanHistorySnapshot? {
        snapshots.first { $0.id == selectedBaselineID }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(
            minWidth: 780,
            idealWidth: 980,
            maxWidth: .infinity,
            minHeight: 480,
            idealHeight: 640,
            maxHeight: .infinity
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("query-plan-history-sheet")
        .task(id: historyReloadVersion) {
            await loadHistory(showProgress: snapshots.isEmpty)
        }
        .task(id: selectedBaselineID) {
            await resolveSelectedComparison()
        }
        .onReceive(AppEvents.shared.queryHistoryDidUpdate) { _ in
            historyReloadVersion += 1
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "Plan History"))
                .font(.headline)
            Text(queryPreview(context.subjectQuery))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        switch loadState {
        case .idle, .loading:
            ProgressView(String(localized: "Loading plan history…"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message):
            ContentUnavailableView(
                String(localized: "Plan History Unavailable"),
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .loaded where snapshots.isEmpty:
            ContentUnavailableView(
                String(localized: "No Earlier Plans"),
                systemImage: "clock.arrow.circlepath",
                description: Text(String(localized: "Run this EXPLAIN again to create a comparison baseline."))
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .loaded:
            historySplitView
        }
    }

    private var historySplitView: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                Text(String(localized: "Earlier Runs"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                Divider()

                List(snapshots, selection: $selectedBaselineID) { snapshot in
                    baselineRow(snapshot)
                        .tag(snapshot.id)
                }
                .listStyle(.sidebar)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("query-plan-history-baseline-list")
            }
            .frame(minWidth: 250, idealWidth: 290)

            comparisonPane
                .frame(minWidth: 480)
        }
    }

    private func baselineRow(_ snapshot: ExplainPlanHistorySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(snapshot.context.capturedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.callout.weight(.medium))
                Spacer(minLength: 4)
                Text(QueryDurationFormatter.string(from: snapshot.executionTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var comparisonPane: some View {
        if let selectedBaseline, let comparisonPresentation {
            VStack(spacing: 0) {
                comparisonHeader(selectedBaseline)
                Divider()

                switch comparisonPresentation {
                case .structured(let comparison):
                    structuredComparison(comparison)
                case .rawOnly(let previous, let current):
                    rawComparison(previous: previous, current: current)
                }
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func comparisonHeader(_ baseline: ExplainPlanHistorySnapshot) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "Baseline"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(baseline.context.capturedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.callout.weight(.medium))
                Text(QueryDurationFormatter.string(from: baseline.executionTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Image(systemName: "arrow.right")
                .foregroundStyle(.tertiary)

            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "Current"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(context.capturedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.callout.weight(.medium))
                Text(currentExecutionTime.map { QueryDurationFormatter.string(from: $0) } ?? "–")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func structuredComparison(_ comparison: QueryPlanComparison) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                metricGrid(comparison.summary)

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: "Node Changes"))
                        .font(.headline)

                    if comparison.nodeChanges.isEmpty {
                        Text(String(localized: "No node changes."))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 12)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(comparison.nodeChanges) { change in
                                nodeChangeRow(change)
                                Divider()
                            }
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("query-plan-history-change-list")
            }
            .padding(16)
        }
    }

    private func metricGrid(_ summary: QueryPlanSummaryComparison) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 7) {
            GridRow {
                Text(String(localized: "Metric"))
                Text(String(localized: "Baseline"))
                Text(String(localized: "Current"))
                Text(String(localized: "Change"))
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)

            Divider().gridCellColumns(4)

            metricRow(
                String(localized: "Cost"),
                delta: summary.rootEstimatedTotalCost,
                format: .decimal
            )
            metricRow(
                String(localized: "Estimated rows"),
                delta: summary.rootEstimatedRows,
                format: .integer
            )
            metricRow(
                String(localized: "Planning time"),
                delta: summary.planningTime,
                format: .milliseconds
            )
            metricRow(
                String(localized: "Execution time"),
                delta: summary.executionTime,
                format: .milliseconds
            )
            metricRow(
                String(localized: "Node count"),
                delta: summary.nodeCount,
                format: .integer
            )
        }
        .monospacedDigit()
    }

    private func metricRow(
        _ name: String,
        delta: QueryPlanMetricDelta,
        format: MetricFormat
    ) -> some View {
        GridRow {
            Text(name)
                .font(.callout)
            Text(format.value(delta.previous))
                .foregroundStyle(.secondary)
            Text(format.value(delta.current))
            Text(format.change(delta))
                .foregroundStyle(delta.hasChanges ? Color.primary : Color.secondary)
        }
    }

    private func nodeChangeRow(_ change: QueryPlanNodeChange) -> some View {
        let style = NodeChangeStyle(change.kind)
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: style.symbolName)
                .foregroundStyle(style.color)
                .frame(width: 18)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(style.label)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(style.color)
                    Text(nodeTitle(change))
                        .font(.callout.weight(.medium))
                }

                ForEach(change.valueChanges) { valueChange in
                    Text(valueChangeText(valueChange))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("query-plan-history-change-\(change.kind.rawValue)")
        .accessibilityLabel("\(style.label): \(nodeTitle(change))")
        .accessibilityValue(QueryPlanHistoryNodeChangeAccessibility.value(change))
    }

    private func rawComparison(previous: String, current: String) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                Text(String(localized: "A structured comparison is unavailable because one plan could not be parsed. Showing raw output."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            HSplitView {
                rawColumn(title: String(localized: "Baseline"), text: previous)
                    .frame(minWidth: 220)
                rawColumn(title: String(localized: "Current"), text: current)
                    .frame(minWidth: 220)
            }
        }
    }

    private func rawColumn(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            ScrollView([.horizontal, .vertical]) {
                Text(verbatim: rawTextForDisplay(text))
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(String(localized: "Close")) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }

    private func loadHistory(showProgress: Bool) async {
        if showProgress {
            loadState = .loading
        }

        let manager = QueryHistoryManager.shared
        guard await manager.isStoreAvailable() else {
            guard !Task.isCancelled else { return }
            loadState = .failed(String(localized: "The query history store could not be opened."))
            return
        }

        let loaded = await manager.explainPlanHistory(matching: context, limit: 50)
        guard !Task.isCancelled else { return }

        let selectedID = selectedBaselineID
        snapshots = loaded
            .filter { $0.id != context.historyId }
            .sorted { lhs, rhs in
                if lhs.context.capturedAt != rhs.context.capturedAt {
                    return lhs.context.capturedAt > rhs.context.capturedAt
                }
                return lhs.id.uuidString > rhs.id.uuidString
            }
        if let selectedID, snapshots.contains(where: { $0.id == selectedID }) {
            selectedBaselineID = selectedID
        } else {
            selectedBaselineID = snapshots.first?.id
        }
        loadState = .loaded
    }

    private func resolveSelectedComparison() async {
        guard let selectedBaseline, let selectionID = selectedBaselineID else {
            comparisonPresentation = nil
            return
        }

        comparisonPresentation = nil
        do {
            try await Task.sleep(for: .milliseconds(150))
        } catch {
            return
        }
        guard selectedBaselineID == selectionID else { return }

        let currentPlan = currentPlan
        let currentRawText = currentRawText
        let previousRawText = await QueryHistoryManager.shared.explainPlanRawText(historyId: selectionID)
        guard !Task.isCancelled, selectedBaselineID == selectionID else { return }
        guard let previousRawText else {
            comparisonPresentation = .rawOnly(
                previous: "",
                current: QueryPlanHistoryRawText.bounded(currentRawText)
            )
            return
        }
        let presentation = await comparisonWorker.resolve(
            previousRawText: previousRawText,
            formatRawValue: selectedBaseline.context.formatRawValue,
            currentPlan: currentPlan,
            currentRawText: currentRawText
        )
        guard !Task.isCancelled,
              selectedBaselineID == selectionID,
              let presentation
        else { return }
        comparisonPresentation = presentation
    }

    private func queryPreview(_ query: String) -> String {
        let query = query as NSString
        let inputWasTruncated = query.length > 2_000
        let bounded = query.substring(to: min(query.length, 2_000))
        let collapsed = bounded
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let collapsedText = collapsed as NSString
        guard collapsedText.length > 160 || inputWasTruncated else { return collapsed }
        return collapsedText.substring(to: min(collapsedText.length, 160)) + "…"
    }

    private func nodeTitle(_ change: QueryPlanNodeChange) -> String {
        guard let relation = change.relation, !relation.isEmpty else { return change.operation }
        return "\(change.operation) · \(relation)"
    }

    private func valueChangeText(_ change: QueryPlanNodeValueChange) -> String {
        QueryPlanHistoryNodeChangeAccessibility.detail(change)
    }

    private func rawTextForDisplay(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? String(localized: "No raw plan output.")
            : text
    }
}

private enum MetricFormat {
    case decimal
    case integer
    case milliseconds

    func value(_ value: Double?) -> String {
        guard let value else { return "–" }
        switch self {
        case .decimal:
            return value.formatted(.number.precision(.fractionLength(0...2)))
        case .integer:
            return value.formatted(.number.precision(.fractionLength(0)))
        case .milliseconds:
            return String(format: String(localized: "%.3f ms"), value)
        }
    }

    func change(_ delta: QueryPlanMetricDelta) -> String {
        guard delta.hasChanges else { return "–" }
        guard let value = delta.delta else { return String(localized: "Changed") }

        let formatted: String
        switch self {
        case .decimal:
            formatted = String(format: "%+.2f", value)
        case .integer:
            formatted = String(format: "%+.0f", value)
        case .milliseconds:
            formatted = String(format: String(localized: "%+.3f ms"), value)
        }

        guard let percent = delta.percentChange else { return formatted }
        return "\(formatted) (\(String(format: "%+.1f%%", percent)))"
    }
}

private struct NodeChangeStyle {
    let symbolName: String
    let label: String
    let color: Color

    init(_ kind: QueryPlanNodeChangeKind) {
        switch kind {
        case .added:
            symbolName = "plus.circle.fill"
            label = String(localized: "Added")
            color = .green
        case .removed:
            symbolName = "minus.circle.fill"
            label = String(localized: "Removed")
            color = .red
        case .modified:
            symbolName = "pencil.circle.fill"
            label = String(localized: "Modified")
            color = .orange
        }
    }
}
