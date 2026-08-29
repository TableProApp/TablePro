//
//  CompareSyncSession.swift
//  TablePro
//
//  The state of one comparison. It holds no driver and performs no I/O: that is
//  `CompareRunner`'s job, the way `QueryExecutionCoordinator` holds a query tab's
//  state and `QueryExecutor` does the talking.
//
//  There are no steps. The window shows the setup, the results and the script at
//  once, and an action is available when its preconditions hold, so re-running a
//  comparison is one click rather than walking backwards through a wizard.
//

import Foundation
import Observation
import os

internal enum CompareSyncActivity: Equatable {
    case idle
    case connecting
    case comparing
    case applying
}

internal enum CompareSyncLastAction: Equatable {
    case none
    case compared(Date, differences: Int)
    case applied(Date, target: String, statements: Int)
}

internal enum CompareDetailPane: String, CaseIterable, Hashable {
    case definitions
    case rows
    case script

    internal var title: String {
        switch self {
        case .definitions: return String(localized: "Definitions")
        case .rows: return String(localized: "Rows")
        case .script: return String(localized: "Script")
        }
    }
}

@MainActor
@Observable
internal final class CompareSyncSession {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "CompareSyncSession")

    // MARK: - Setup

    internal var mode: CompareSyncMode = .structure
    internal var source: DatabaseEndpoint?
    internal var target: DatabaseEndpoint?
    internal var structureOptions = StructureCompareOptions.default
    internal var dataOptions = DataCompareOptions.default
    internal var executionSettings = CompareSyncExecutionSettings()
    internal var includedKinds: Set<CompareObjectKind> = [.table]

    // MARK: - Results

    internal var report: CompareReport?
    internal var dataPlans: [DataComparePlan] = []
    internal var actions: [String: TableSyncAction] = [:]
    internal var statements: [SyncStatement] = []
    internal var runResult: CompareSyncRunResult?
    internal var sourceSnapshots: [String: TableStructureSnapshot] = [:]
    internal var targetSnapshots: [String: TableStructureSnapshot] = [:]

    // MARK: - Presentation

    internal var selectedObjectId: String?
    internal var selectedPlanId: String?
    internal var detailPane: CompareDetailPane = .definitions
    internal var searchText = ""
    internal var showsIdentical = false
    internal var grouping: CompareGrouping = .byDifference

    // MARK: - Activity

    internal var activity: CompareSyncActivity = .idle
    internal var errorMessage: String?
    internal var informationalMessage: String?
    internal var lastAction: CompareSyncLastAction = .none
    internal var progress: Progress?
    internal var hasWrittenToTarget = false

    /// True once a script has run against the target, until the next comparison.
    internal var isStaleAfterApply = false
    internal var runTask: Task<Void, Never>?
    internal var pendingSelection: Set<String> = []

    internal init() {}

    // MARK: - Direction

    internal var directionSentence: String? {
        guard let source, let target else { return nil }
        return String(
            format: String(localized: "Compare %@ and write changes to %@."),
            source.qualifiedDescription, target.qualifiedDescription
        )
    }

    internal var canSwap: Bool {
        source != nil || target != nil
    }

    internal func swapEndpoints() {
        let previousSource = source
        source = target
        target = previousSource
        resetComparison()
    }

    internal var canCompare: Bool {
        compareDisabledReason == nil
    }

    internal var canGenerateStructureScript: Bool {
        guard mode == .structure, let source, let target else { return false }
        return CompareSyncEngineFamily.canGenerateStructureScript(from: source.databaseType, to: target.databaseType)
    }

    internal var crossEngineNotice: String? {
        guard let source, let target else { return nil }
        if mode == .structure, !canGenerateStructureScript {
            return CompareSyncEngineFamily.structureScriptRefusal(from: source.databaseType, to: target.databaseType)
        }
        return CompareSyncEngineFamily.crossEngineDataWarning(from: source.databaseType, to: target.databaseType)
    }

    // MARK: - Banner

    internal var bannerText: String {
        switch activity {
        case .applying:
            return String(format: String(localized: "Applying to %@…"), target?.qualifiedDescription ?? "")
        case .comparing, .connecting:
            return String(localized: "Comparing only. Nothing has been written.")
        case .idle:
            return idleBannerText
        }
    }

    private var idleBannerText: String {
        switch lastAction {
        case .none:
            return String(localized: "Comparing only. Nothing has been written.")
        case .compared(let date, let differences):
            /// The count is not the first argument, so a plural variation on the format string
            /// cannot key on it; the singular is chosen here instead. Without this the strip read
            /// "1 differences".
            let time = Self.timeFormatter.string(from: date)
            guard differences != 1 else {
                return String(
                    format: String(localized: "Compared %@. 1 difference. Nothing has been written."), time
                )
            }
            return String(
                format: String(localized: "Compared %@. %d differences. Nothing has been written."),
                time, differences
            )
        case .applied(let date, let name, let statements):
            let time = Self.timeFormatter.string(from: date)
            guard statements != 1 else {
                return String(format: String(localized: "Applied to %@ at %@. 1 statement."), name, time)
            }
            return String(
                format: String(localized: "Applied to %@ at %@. %d statements."), name, time, statements
            )
        }
    }

    // MARK: - Selection

    internal func action(for result: CompareObjectResult) -> TableSyncAction {
        actions[result.id] ?? .skip
    }

    internal func isIncluded(_ result: CompareObjectResult) -> Bool {
        action(for: result) != .skip
    }

    internal func setAction(_ action: TableSyncAction, for result: CompareObjectResult) {
        actions[result.id] = action
        invalidateScript()
    }

    internal func setIncluded(_ included: Bool, for result: CompareObjectResult) {
        setAction(included ? result.suggestedAction : .skip, for: result)
    }

    internal func setIncluded(_ included: Bool, forIds ids: [String]) {
        guard let report else { return }
        let byId = Dictionary(report.comparable.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for id in ids {
            guard let result = byId[id] else { continue }
            actions[result.id] = included ? result.suggestedAction : .skip
        }
        invalidateScript()
    }

    internal var selectedObjectCount: Int {
        switch mode {
        case .structure:
            return actions.values.filter { $0 != .skip }.count
        case .data:
            return dataPlans.filter { $0.isEnabled && $0.isComparable && ($0.summary?.differenceCount ?? 0) > 0 }.count
        }
    }

    internal var canBuildScript: Bool {
        scriptDisabledReason == nil
    }

    internal var canApply: Bool {
        applyDisabledReason == nil
    }

    // MARK: - Why an action is unavailable

    /// The HIG asks an app to "show people when a command can't be carried out and help people
    /// understand why", and to give a disabled control a tooltip naming the unmet precondition
    /// rather than repeating its own name. Validation used to compute these conditions and throw
    /// the reason away, returning a bare Bool, so every disabled toolbar item said only what it
    /// was called.
    internal var compareDisabledReason: String? {
        if isBusy { return String(localized: "A comparison is already running.") }
        guard let source else { return String(localized: "Choose a source to compare from.") }
        guard let target else { return String(localized: "Choose a target to compare against.") }
        if let refusal = target.ineligibleAsTargetReason { return refusal }
        guard source.id != target.id else {
            return String(localized: "The source and the target are the same database.")
        }
        return nil
    }

    internal var scriptDisabledReason: String? {
        if isBusy { return String(localized: "A comparison is already running.") }
        if isStaleAfterApply {
            return String(localized: "The script already ran. Compare again to see where the target stands.")
        }
        if report == nil, dataPlans.isEmpty {
            return String(localized: "Compare the two databases first.")
        }
        if mode == .structure, !canGenerateStructureScript {
            return crossEngineNotice ?? String(localized: "These two engines cannot share a script.")
        }
        guard selectedObjectCount > 0 else {
            return mode == .structure
                ? String(localized: "Include at least one object to generate a script for it.")
                : String(localized: "Include at least one table to generate a script for it.")
        }
        return nil
    }

    internal var applyDisabledReason: String? {
        if isBusy { return String(localized: "A run is already in progress.") }
        if isStaleAfterApply {
            return String(localized: "The script already ran. Compare again to see where the target stands.")
        }
        guard target?.canBeWrittenTo == true else {
            return target?.ineligibleAsTargetReason ?? String(localized: "Choose a target to write to.")
        }
        guard !statements.isEmpty else { return String(localized: "Generate the script first.") }
        guard unacknowledgedHazardCount == 0 else {
            guard unacknowledgedHazardCount != 1 else {
                return String(localized: "1 statement would destroy data and is not allowed yet.")
            }
            return String(
                format: String(localized: "%d statements would destroy data and are not allowed yet."),
                unacknowledgedHazardCount
            )
        }
        return nil
    }

    /// A statement carrying an unacknowledged hazard is why Apply stays disabled rather than
    /// silently dropping it: the count the user is about to run has to be the count they saw.
    internal var unacknowledgedHazardCount: Int {
        statements.filter { $0.isRefusedByDefault && !executionSettings.canRun($0) }.count
    }

    internal var runnableStatementCount: Int {
        statements.filter { executionSettings.canRun($0) }.count
    }

    // MARK: - Results view

    internal var visibleResults: [CompareObjectResult] {
        guard let report else { return [] }
        var results = report.comparable.filter { includedKinds.contains($0.identity.kind) }
        if !showsIdentical {
            results = results.filter { $0.status != .identical }
        }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return results }
        return results.filter { $0.identity.displayName.localizedCaseInsensitiveContains(query) }
    }

    internal var selectedResult: CompareObjectResult? {
        guard let selectedObjectId else { return nil }
        return report?.results.first { $0.id == selectedObjectId }
    }

    internal var selectedPlan: DataComparePlan? {
        guard let selectedPlanId else { return nil }
        return dataPlans.first { $0.id == selectedPlanId }
    }

    /// What the window's bottom status bar reads. The HIG names a count of a window's contents as
    /// the sanctioned use of a bottom bar, with Finder's item and selection counts as the example.
    internal var statusCounts: [CompareStatusCount] {
        switch mode {
        case .structure:
            guard let report else { return [] }
            return [
                CompareStatusCount(status: .onlyInSource, count: report.count(of: .onlyInSource)),
                CompareStatusCount(status: .differs, count: report.count(of: .differs)),
                CompareStatusCount(status: .onlyInTarget, count: report.count(of: .onlyInTarget)),
                CompareStatusCount(status: .identical, count: report.count(of: .identical))
            ]
        case .data:
            guard !dataPlans.isEmpty else { return [] }
            let compared = dataPlans.compactMap { $0.summary }
            return [
                CompareStatusCount(status: .onlyInSource, count: compared.reduce(0) { $0 + $1.insertCount }),
                CompareStatusCount(status: .differs, count: compared.reduce(0) { $0 + $1.updateCount }),
                CompareStatusCount(status: .onlyInTarget, count: compared.reduce(0) { $0 + $1.deleteCount }),
                CompareStatusCount(status: .identical, count: compared.reduce(0) { $0 + $1.identicalCount })
            ]
        }
    }

    internal var includedCount: Int {
        selectedObjectCount
    }

    internal var truncatedPlanNames: [String] {
        dataPlans.filter { $0.summary?.truncatedEntries == true }.map { $0.id }
    }

    internal var dataDifferenceTotal: Int {
        dataPlans.compactMap { $0.summary?.differenceCount }.reduce(0, +)
    }

    // MARK: - Lifecycle

    /// `lastAction` is what the banner reads, so it is part of the result and is cleared with it.
    /// Leaving it behind made the banner claim "52 differences" over a pane reading "No Comparison
    /// Yet": changing an endpoint correctly discarded the answer, and the banner kept advertising
    /// it. `hasWrittenToTarget` deliberately survives, because a write already happened and no
    /// later comparison makes that untrue.
    internal func resetComparison() {
        report = nil
        sourceSnapshots = [:]
        targetSnapshots = [:]
        dataPlans = []
        actions = [:]
        selectedObjectId = nil
        selectedPlanId = nil
        runResult = nil
        errorMessage = nil
        informationalMessage = nil
        lastAction = .none
        isStaleAfterApply = false
        invalidateScript()
    }

    /// After a run the report describes a target that has since changed, so it is stale rather than
    /// wrong: it stays on screen to be read, and every action that would write again is withdrawn
    /// until the user compares once more.
    internal func markAppliedAndStale() {
        statements = []
        actions = [:]
        for index in dataPlans.indices {
            dataPlans[index].isEnabled = false
        }
        isStaleAfterApply = true
    }

    internal func invalidateScript() {
        statements = []
        runResult = nil
    }

    internal func cancelRunningWork() {
        progress?.cancel()
        runTask?.cancel()
    }

    internal var isBusy: Bool {
        activity != .idle
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()
}

internal enum CompareGrouping: String, CaseIterable, Hashable {
    case byDifference
    case byObjectType
    case none

    internal var title: String {
        switch self {
        case .byDifference: return String(localized: "Difference")
        case .byObjectType: return String(localized: "Object Type")
        case .none: return String(localized: "None")
        }
    }
}

/// One cell of the bottom status bar. Data mode reuses the structure vocabulary deliberately: an
/// insert is a row that exists only on the source, a delete only on the target, so the same four
/// words describe both comparisons and the bar does not change shape between modes.
internal struct CompareStatusCount: Identifiable, Hashable {
    internal let status: TableDiffStatus
    internal let count: Int

    internal var id: String { status.rawValue }
}
