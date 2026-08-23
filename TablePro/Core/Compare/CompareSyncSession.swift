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
    internal var source: CompareSyncEndpoint?
    internal var target: CompareSyncEndpoint?
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
        guard let source, let target else { return false }
        guard target.canBeWrittenTo else { return false }
        guard activity == .idle else { return false }
        return source.id != target.id
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
            return String(
                format: String(localized: "Compared %@. %d differences. Nothing has been written."),
                Self.timeFormatter.string(from: date), differences
            )
        case .applied(let date, let name, let statements):
            return String(
                format: String(localized: "Applied to %@ at %@. %d statements."),
                name, Self.timeFormatter.string(from: date), statements
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
        guard activity == .idle else { return false }
        switch mode {
        case .structure:
            return selectedObjectCount > 0 && canGenerateStructureScript
        case .data:
            return selectedObjectCount > 0
        }
    }

    internal var canApply: Bool {
        activity == .idle && !statements.isEmpty && target?.canBeWrittenTo == true
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

    internal var truncatedPlanNames: [String] {
        dataPlans.filter { $0.summary?.truncatedEntries == true }.map { $0.id }
    }

    internal var dataDifferenceTotal: Int {
        dataPlans.compactMap { $0.summary?.differenceCount }.reduce(0, +)
    }

    // MARK: - Lifecycle

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
        invalidateScript()
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
