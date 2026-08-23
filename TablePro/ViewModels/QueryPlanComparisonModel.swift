//
//  QueryPlanComparisonModel.swift
//  TablePro
//
//  Drives the plan pane's Compare mode: which earlier runs exist, which one is the baseline, and
//  what changed between it and the plan on screen.
//

import Combine
import Foundation
import Observation
import TableProPluginKit

/// What the pane can show for the selected baseline.
enum QueryPlanComparisonContent: Hashable, Sendable {
    /// Both plans parsed, so the difference can be stated in terms of nodes and metrics.
    case diff(QueryPlanDiff)
    /// One of them did not parse. The plans are still comparable as text, which is what the
    /// database gave us.
    case rawText(baseline: [String], current: [String])
}

/// Why there is nothing to compare against yet.
enum QueryPlanComparisonEmptyReason: Hashable, Sendable {
    case noEarlierRuns
    case notSaved(QueryPlanCaptureSkipReason)
    case capturePaused

    var title: String {
        switch self {
        case .noEarlierRuns: return String(localized: "No Earlier Plans")
        case .notSaved: return String(localized: "Plan Not Saved")
        case .capturePaused: return String(localized: "Query History Is Paused")
        }
    }

    var message: String {
        switch self {
        case .noEarlierRuns:
            return String(localized: "Run this EXPLAIN again after a change to compare the two plans.")
        case .notSaved(let reason):
            return reason.explanation
        case .capturePaused:
            return String(localized: "Plans are saved with query history. Resume history to start collecting them.")
        }
    }

    var systemImage: String {
        switch self {
        case .noEarlierRuns: return "clock.arrow.circlepath"
        case .notSaved: return "doc.badge.ellipsis"
        case .capturePaused: return "pause.circle"
        }
    }
}

@MainActor
@Observable
final class QueryPlanComparisonModel {
    enum State: Hashable, Sendable {
        case loading
        case empty(QueryPlanComparisonEmptyReason)
        case content(QueryPlanComparisonContent)
        case unavailable(String)
    }

    /// A plan longer than this is not read line by line by anybody, and rendering all of it costs
    /// more than the answer is worth. Only the text fallback is bounded; a parsed plan is compared
    /// as a tree and has no such problem.
    nonisolated static let maximumComparedLineCount = 2_000

    /// Enough runs to find the one before yesterday's deploy, few enough to stay a menu.
    nonisolated static let baselineListLimit = 50

    private(set) var baselines: [QueryPlanSnapshotSummary] = []
    private(set) var state: State = .loading

    var selectedBaselineId: UUID? {
        didSet {
            guard oldValue != selectedBaselineId else { return }
            reloadComparison()
        }
    }

    private var context: QueryPlanContext?
    private var currentPlan: QueryPlan?
    private var currentRawText = ""
    private let history: QueryPlanSnapshotReading
    private let isCapturePaused: @MainActor () -> Bool
    private var updateSubscription: AnyCancellable?
    private var loadTask: Task<Void, Never>?
    private var comparisonTask: Task<Void, Never>?

    init(
        history: QueryPlanSnapshotReading = QueryHistoryManager.shared,
        isCapturePaused: @escaping @MainActor () -> Bool = { QueryHistoryCaptureStore.isPaused }
    ) {
        self.history = history
        self.isCapturePaused = isCapturePaused
    }

    var selectedBaseline: QueryPlanSnapshotSummary? {
        baselines.first { $0.id == selectedBaselineId }
    }

    /// Called whenever the pane's result changes. Reloading on the context's identity rather than on
    /// every render keeps a re-run of the same statement from throwing away the chosen baseline.
    func activate(context: QueryPlanContext, plan: QueryPlan?, rawText: String) {
        self.context = context
        currentPlan = plan
        currentRawText = rawText
        startObserving(connectionId: context.identity.scope.connectionId)
        reloadBaselines()
    }

    func deactivate() {
        updateSubscription?.cancel()
        updateSubscription = nil
        loadTask?.cancel()
        comparisonTask?.cancel()
    }

    func setPinned(_ isPinned: Bool, snapshotId: UUID) {
        Task { [history] in
            await history.setPlanSnapshotPinned(id: snapshotId, isPinned: isPinned)
            reloadBaselines()
        }
    }

    // MARK: - Loading

    private func startObserving(connectionId: UUID) {
        guard updateSubscription == nil else { return }
        /// Scoped to this connection and debounced, the same shape the history drawer and the
        /// insights tab use. Saving a grid full of edits records one entry per statement, and an
        /// unfiltered, undebounced reload turns that burst into a burst of queries.
        updateSubscription = AppEvents.shared.queryHistoryDidUpdate
            .filter { $0 == nil || $0 == connectionId }
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.reloadBaselines() }
    }

    private func reloadBaselines() {
        guard let context else { return }
        loadTask?.cancel()
        loadTask = Task { [history] in
            guard await history.isStoreAvailable() else {
                guard !Task.isCancelled else { return }
                state = .unavailable(String(localized: "The query history store could not be opened."))
                return
            }
            let loaded = await history.planSnapshots(
                matching: context.identity,
                excluding: context.storedSnapshotId,
                limit: Self.baselineListLimit
            )
            guard !Task.isCancelled else { return }
            baselines = loaded
            if let selectedBaselineId, loaded.contains(where: { $0.id == selectedBaselineId }) {
                reloadComparison()
                return
            }
            selectedBaselineId = loaded.first?.id
            if selectedBaselineId == nil {
                state = .empty(emptyReason)
            }
        }
    }

    private var emptyReason: QueryPlanComparisonEmptyReason {
        if let reason = context?.skipReason { return .notSaved(reason) }
        if isCapturePaused() { return .capturePaused }
        return .noEarlierRuns
    }

    private func reloadComparison() {
        comparisonTask?.cancel()
        guard let selectedBaselineId else {
            state = .empty(emptyReason)
            return
        }
        guard let context else { return }

        let plan = currentPlan
        let rawText = currentRawText
        let format = context.identity.format
        comparisonTask = Task { [history] in
            guard let baselineRaw = await history.planSnapshotRawText(id: selectedBaselineId) else {
                guard !Task.isCancelled else { return }
                state = .unavailable(String(localized: "This plan is no longer stored."))
                return
            }
            let content = await Self.makeContent(
                baselineRawText: baselineRaw,
                format: format,
                currentPlan: plan,
                currentRawText: rawText
            )
            guard !Task.isCancelled, self.selectedBaselineId == selectedBaselineId else { return }
            state = .content(content)
        }
    }

    /// Parsing and diffing are the only expensive part, and neither touches the model, so they run
    /// off the main actor. `nonisolated async` is what moves them there; a detached task would
    /// escape the model's isolation for no benefit.
    nonisolated private static func makeContent(
        baselineRawText: String,
        format: ExplainPlanFormat,
        currentPlan: QueryPlan?,
        currentRawText: String
    ) async -> QueryPlanComparisonContent {
        guard let currentPlan,
              let baselinePlan = ExplainPlanParserRegistry.plan(from: baselineRawText, format: format)
        else {
            return .rawText(
                baseline: boundedLines(baselineRawText),
                current: boundedLines(currentRawText)
            )
        }
        return .diff(QueryPlanDiff.compare(baseline: baselinePlan, current: currentPlan))
    }

    nonisolated private static func boundedLines(_ text: String) -> [String] {
        let lines = SqlNormalizer.lines(text)
        guard lines.count > maximumComparedLineCount else { return lines }
        return Array(lines.prefix(maximumComparedLineCount))
            + [String(localized: "Output truncated for display")]
    }
}
