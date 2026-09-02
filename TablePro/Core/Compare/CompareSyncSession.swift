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
    case buildingScript
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

    /// True once the table list has been read for this pair, which an empty `dataPlans` cannot say
    /// on its own. Without it "not read yet" and "these two share no table" are the same state, and
    /// the pane claims the second whenever the first is true.
    internal var hasLoadedDataPlans = false

    /// Tables that were listed on one side and whose metadata could not be read. An empty plan list
    /// with unreadable tables behind it is not "these two share no table", and saying so sent the
    /// reader looking for a naming difference that was not there.
    internal var unreadableTableCount = 0
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

    /// Which setup the answers on screen belong to.
    ///
    /// `Task.cancel()` is cooperative, so work that has already reached a driver finishes whatever
    /// the window does next, and the setup it was started for can be gone by the time it has an
    /// answer. Publishing that answer puts one pair's plans, snapshots or statements behind another
    /// pair's Compare and Apply, which is the same trap `ConnectionAttemptRegistry` exists for on
    /// the connection side. Every async publisher captures this and drops its result if it moved.
    private(set) var setupGeneration = 0

    /// Which set of choices the script on screen was built from.
    ///
    /// `setupGeneration` cannot answer this. Including an object, changing a key column, excluding
    /// a row or flipping a write policy all invalidate the script without changing the setup, and
    /// those controls stay live while a build is in flight. A build that finished after one of them
    /// would republish statements for an object the user had just excluded, and Apply would then
    /// open on them, because an ordinary INSERT or ALTER is not a hazard `runRefusalReason` catches.
    private(set) var scriptRevision = 0

    /// Which question the answers on screen were computed for.
    ///
    /// A comparison invalidates the script it just made stale, so a run that fenced its own report
    /// on `scriptRevision` could never publish one: it had already advanced the revision itself.
    /// Ticking a table or excluding a row is the other half of the same distinction. It changes
    /// which statements come out of an answer that still stands, so it invalidates the script and
    /// must not throw away a comparison that has been streaming rows for minutes.
    private(set) var answerRevision = 0

    /// A setup problem, which outlives the comparison it interrupted. `errorMessage` is cleared by
    /// the next reset, and a reset is exactly what changing the setup does, so a message about the
    /// setup itself cannot live there: loading a profile whose connection is gone reported the
    /// failure and had it wiped by the option change the same load caused.
    internal var setupErrorMessage: String?

    /// The two things the setup needs from outside the session: where a saved comparison lives, and
    /// which connections a stored scope can resolve against. Injected rather than reached for, so
    /// the restore rules can be exercised without writing to the user's own defaults.
    @ObservationIgnored internal let profileStorage: CompareSyncProfileStorage
    @ObservationIgnored internal let connectionsProvider: @MainActor () -> [DatabaseConnection]

    internal init(
        profileStorage: CompareSyncProfileStorage = .shared,
        connectionsProvider: @escaping @MainActor () -> [DatabaseConnection] = {
            ConnectionStorage.shared.loadConnections()
        }
    ) {
        self.profileStorage = profileStorage
        self.connectionsProvider = connectionsProvider
    }

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

    /// The setup message says an endpoint could not be resolved, so choosing one clears it.
    internal func clearSetupErrorIfResolved() {
        guard source != nil, target != nil else { return }
        setupErrorMessage = nil
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
        case .comparing, .connecting, .buildingScript:
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

    /// Apply is available whenever there is a comparison to apply, and it builds its own script
    /// when none has been built. Requiring Generate Script first made every sync a three-press
    /// sequence for a script the Apply sheet shows in full anyway.
    ///
    /// An unallowed hazard is deliberately not a reason any more. The allowance for one lives
    /// inside the Apply sheet, so withholding the sheet until every hazard was allowed put the
    /// control behind the door it was locking. The sheet's own Apply button still refuses to run
    /// while one is outstanding, which is where the refusal belongs.
    internal var applyDisabledReason: String? {
        if isBusy { return String(localized: "A run is already in progress.") }
        if isStaleAfterApply {
            return String(localized: "The script already ran. Compare again to see where the target stands.")
        }
        guard target?.canBeWrittenTo == true else {
            return target?.ineligibleAsTargetReason ?? String(localized: "Choose a target to write to.")
        }
        guard statements.isEmpty else { return nil }
        return scriptDisabledReason
    }

    /// What the Apply sheet's own button answers to, and what the run itself refuses on. A
    /// statement carrying an unallowed hazard stops the run rather than being dropped from it: the
    /// count the user is about to run has to be the count they saw.
    internal var runRefusalReason: String? {
        if let reason = applyDisabledReason { return reason }
        if statements.isEmpty { return String(localized: "There is no script to run.") }
        guard unacknowledgedHazardCount == 0 else {
            guard unacknowledgedHazardCount != 1 else {
                return String(localized: "1 statement would destroy data and is not allowed yet.")
            }
            return String(
                format: String(localized: "%d statements would destroy data and are not allowed yet."),
                unacknowledgedHazardCount
            )
        }
        guard runnableStatementCount > 0 else { return String(localized: "No statement is allowed to run.") }
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
        /// The setup the work in flight was started for is the one being replaced, so it is stopped
        /// here rather than left holding `runTask`. A preload taking that slot from an orphaned run
        /// left Stop with nothing to cancel while the run went on reading.
        cancelRunningWork()
        report = nil
        sourceSnapshots = [:]
        targetSnapshots = [:]
        dataPlans = []
        hasLoadedDataPlans = false
        unreadableTableCount = 0
        actions = [:]
        selectedObjectId = nil
        selectedPlanId = nil
        runResult = nil
        errorMessage = nil
        informationalMessage = nil
        lastAction = .none
        isStaleAfterApply = false
        invalidateAnswer()
        setupGeneration &+= 1
        /// Every path that resets a comparison is a path that changed the setup: an endpoint, the
        /// mode, or an option. So this is also where the setup is written down, and reopening the
        /// window lands on the same pair instead of on two empty pickers.
        rememberSetup()
    }

    /// True while the answer in hand still belongs to the setup on screen.
    internal func isCurrent(_ generation: Int) -> Bool {
        generation == setupGeneration
    }

    /// What one run was started for, captured before it can suspend. Every helper takes the
    /// caller's claim rather than reading the session again: re-reading inside a callee adopts
    /// whatever the setup has become, which is exactly the ownership the fence is meant to check.
    internal struct RunClaim: Sendable {
        internal let setup: Int
        internal let answer: Int
        internal let script: Int
        internal let mode: CompareSyncMode
    }

    internal var currentClaim: RunClaim {
        RunClaim(setup: setupGeneration, answer: answerRevision, script: scriptRevision, mode: mode)
    }

    /// For statements, which describe one setup, one answer and one set of choices.
    internal func owns(_ claim: RunClaim) -> Bool {
        ownsAnswer(claim) && claim.script == scriptRevision
    }

    /// For a comparison's own results and for anything it reports about itself. A run advances the
    /// script revision as it publishes, so it cannot be fenced on the revision it started with.
    internal func ownsAnswer(_ claim: RunClaim) -> Bool {
        claim.setup == setupGeneration && claim.answer == answerRevision
    }

    /// The one place a table list is published, so the tables a saved comparison asked for are
    /// applied where the list arrives rather than at the next Compare. Left in `pendingSelection`,
    /// they were reapplied later over whatever the user had ticked in the meantime.
    internal func adoptDataPlans(_ plans: [DataComparePlan]) {
        var adopted = plans
        if !pendingSelection.isEmpty {
            for index in adopted.indices {
                adopted[index].isEnabled = pendingSelection.contains(adopted[index].id)
            }
            pendingSelection = []
        }
        let previousSelection = selectedPlanId
        dataPlans = adopted
        hasLoadedDataPlans = true
        /// A rebuild keeps whatever row the user was reading, when that table is still there. Only
        /// a list that no longer holds it falls back to the first table taking part.
        if let previousSelection, adopted.contains(where: { $0.id == previousSelection }) {
            selectedPlanId = previousSelection
            return
        }
        selectedPlanId = adopted.first { $0.isEnabled && $0.isComparable }?.id ?? adopted.first?.id
    }

    /// The one place a structure report's inclusions are published, so what the user ticked while
    /// the comparison ran survives it. The Include controls stay live throughout, and a rebuild
    /// that reset them to nothing discarded every choice made during the run. This is the same rule
    /// the data side already follows, where a rebuilt plan carries the tick it had.
    internal func adoptActions(for report: CompareReport) {
        let carried = actions
        actions = [:]
        for result in report.comparable {
            if let action = carried[result.id] {
                actions[result.id] = action
            } else if pendingSelection.contains(result.id) {
                actions[result.id] = result.suggestedAction
            }
        }
        pendingSelection = []
    }

    /// A comparison streams every row of both sides, so the plans it started from can be minutes
    /// old by the time it has summaries for them, and the ticks, keys and row exclusions stay live
    /// throughout. Writing the run's own array back put every one of those edits behind the list it
    /// captured before the first row was read. Only the summary belongs to the run, so only the
    /// summary is carried over, and only onto a plan still asking the question the run answered.
    internal func applyComparedSummaries(from compared: [DataComparePlan]) {
        let byId = Dictionary(compared.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for index in dataPlans.indices {
            guard let run = byId[dataPlans[index].id],
                  run.keyColumns == dataPlans[index].keyColumns,
                  run.columns == dataPlans[index].columns else { continue }
            dataPlans[index].summary = run.summary
            dataPlans[index].unavailableReason = run.unavailableReason
        }
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
        scriptRevision &+= 1
    }

    /// For the edits that make a computed answer wrong rather than merely restating which parts of
    /// it to apply: a new setup, a new key column, a new set of compared columns.
    internal func invalidateAnswer() {
        answerRevision &+= 1
        invalidateScript()
    }

    /// Cancelling advances both revisions as well as asking the task to stop, because
    /// `Task.cancel()` is cooperative: a build already inside a driver call finishes and would
    /// otherwise publish over a comparison the user has stopped.
    ///
    /// It advances them without clearing what is on screen. Apply cancels the work in flight and
    /// then reads the very statements it is about to run, so discarding the script here left every
    /// confirmed Apply executing nothing and reporting success.
    internal func cancelRunningWork() {
        progress?.cancel()
        runTask?.cancel()
        scriptRevision &+= 1
        answerRevision &+= 1
    }

    /// The user's own Stop, which reports itself here rather than waiting for the task to notice.
    /// `Task.cancel()` is cooperative and a run already inside a driver call may never observe it,
    /// so a message published from the cancellation path is a message that may never arrive; and a
    /// run that does observe it can no longer tell the user's Stop from being superseded by the
    /// next run, because both reach it the same way.
    internal func stopRunningWork() {
        let stopped = activity
        cancelRunningWork()
        switch stopped {
        case .idle:
            return
        case .applying:
            informationalMessage = String(
                localized: "Sync stopped. Statements that already ran stay applied."
            )
        case .buildingScript:
            informationalMessage = String(localized: "Script generation cancelled.")
        case .comparing, .connecting:
            informationalMessage = String(localized: "Comparison cancelled.")
        }
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
