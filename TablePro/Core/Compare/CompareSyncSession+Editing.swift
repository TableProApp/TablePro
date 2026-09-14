//
//  CompareSyncSession+Editing.swift
//  TablePro
//
//  Editing a comparison after a first run: each table's scope (key columns,
//  compared columns, filter, row limit), which rows are excluded, and the saved
//  setups.
//
//  Every scope edit clears that table's answer rather than adjusting it. A new
//  key, filter or limit asks a different question, so the previous answer is
//  not a stale version of the new one.
//

import Foundation

internal extension CompareSyncSession {
    // MARK: - Target

    /// Read from the connection as it stands now, not from the endpoint, which captured the level
    /// when the target was picked. A connection moved to Read-Only afterwards, or held there by a
    /// managed policy, kept Apply enabled until the execution gate refused the confirmed run.
    var targetWriteRefusal: String? {
        guard let target else { return nil }
        let level = connectionsProvider().first { $0.id == target.connectionId }?.safeModeLevel
            ?? target.safeModeLevel
        guard level.blocksAllWrites else { return nil }
        return String(localized: "Read-Only. Choose a different connection to write changes to.")
    }

    func nonTransactionalTables(in statements: [SyncStatement]) -> Set<String> {
        guard let target else { return [] }
        let names = Set(statements.map(\.objectName))
        return Set(
            dataPlans
                .filter {
                    names.contains($0.id)
                        && DataSyncTransactionality.cannotRollBack(
                            storageEngine: $0.targetStorageEngine, databaseType: target.databaseType
                        )
                }
                .map(\.id)
        )
    }

    /// What the run did, in the window rather than in the sheet that closed before it started.
    func reportRunResult(_ result: CompareSyncRunResult, target: DatabaseEndpoint) {
        if result.rollbackLeftWritesInPlace {
            errorMessage = String(
                format: String(
                    localized: "The run was rolled back, but %@ cannot roll back, so the rows already written there stay. Compare again to see where the target stands."
                ),
                ListFormatter.localizedString(byJoining: result.nonTransactionalObjects)
            )
            return
        }
        if let commitFailure = result.commitFailure {
            errorMessage = String(
                format: String(localized: "The statements ran but the transaction could not be committed: %@"),
                commitFailure
            )
            return
        }
        guard result.failedCount > 0 else { return }
        errorMessage = result.rolledBack
            ? String(
                format: String(localized: "%d statements failed, so the run was rolled back and %@ is unchanged."),
                result.failedCount, target.qualifiedDescription
            )
            : String(
                format: String(
                    localized: "%d statements failed. What already ran stays applied. Compare again to see where the target stands."
                ),
                result.failedCount
            )
    }

    // MARK: - Key columns

    func setKeyColumns(_ columns: [String], for planId: String) {
        updateScope(of: planId, clearingRowExclusions: true) { $0.keyColumns = columns }
    }

    func toggleKeyColumn(_ column: String, for planId: String) {
        guard let plan = dataPlans.first(where: { $0.id == planId }) else { return }
        var columns = plan.keyColumns
        if let existing = columns.firstIndex(where: { $0.caseInsensitiveCompare(column) == .orderedSame }) {
            columns.remove(at: existing)
        } else {
            columns.append(column)
        }
        setKeyColumns(columns, for: planId)
    }

    // MARK: - Compared columns

    func isColumnCompared(_ column: String, in planId: String) -> Bool {
        guard let plan = dataPlans.first(where: { $0.id == planId }) else { return true }
        return !plan.scope.isExcluded(column)
    }

    /// A row exclusion is keyed on the row's identity, which only the key columns decide, so
    /// changing which columns take part keeps every per-row decision.
    func toggleComparedColumn(_ column: String, for planId: String) {
        let excluded = isColumnCompared(column, in: planId)
        updateScope(of: planId, clearingRowExclusions: false) { $0.setExcluded(excluded, column: column) }
    }

    // MARK: - Filter and row limit

    func setSourceFilter(_ text: String, for planId: String) {
        updateScope(of: planId, clearingRowExclusions: true) { $0.sourceFilter = text }
    }

    func setTargetFilter(_ text: String, for planId: String) {
        updateScope(of: planId, clearingRowExclusions: true) { $0.targetFilter = text }
    }

    func setUsesSameFilterForTarget(_ same: Bool, for planId: String) {
        updateScope(of: planId, clearingRowExclusions: true) { scope in
            scope.targetFilter = same ? nil : (scope.targetFilter ?? scope.sourceFilter)
        }
    }

    func setRowLimit(_ limit: Int?, for planId: String) {
        updateScope(of: planId, clearingRowExclusions: true) { $0.setRowLimit(limit) }
    }

    private func updateScope(
        of planId: String,
        clearingRowExclusions: Bool,
        _ change: (inout DataTableScope) -> Void
    ) {
        guard canChangeSetup, let index = dataPlans.firstIndex(where: { $0.id == planId }) else { return }
        var scope = dataPlans[index].scope
        change(&scope)
        guard scope != dataPlans[index].scope else { return }
        dataPlans[index].scope = scope
        dataPlans[index].summary = nil
        dataPlans[index].comparisonFailure = nil
        if clearingRowExclusions {
            dataPlans[index].excludedRowKeys = []
        }
        dataPlans[index].unavailableReason = DataComparePlan.unavailableReason(for: dataPlans[index])
        invalidateAnswer()
        rememberSetup()
    }

    // MARK: - Inclusion

    func setPlanEnabled(_ enabled: Bool, for planId: String) {
        guard canChangeSetup, let index = dataPlans.firstIndex(where: { $0.id == planId }) else { return }
        dataPlans[index].isEnabled = enabled
        invalidateScript()
    }

    func setAllPlansEnabled(_ enabled: Bool) {
        guard canChangeSetup else { return }
        for index in dataPlans.indices where dataPlans[index].isComparable {
            dataPlans[index].isEnabled = enabled
        }
        invalidateScript()
    }

    /// An option that changes how two values are judged changes every table's answer.
    func clearDataSummaries() {
        for index in dataPlans.indices {
            dataPlans[index].summary = nil
            dataPlans[index].comparisonFailure = nil
        }
        invalidateAnswer()
    }

    // MARK: - Row inclusion

    /// Row-level exclusion can only name a row the review pane actually showed. Past the retention
    /// cap the script is built from a fresh streamed pass, so an unseen row is included by
    /// definition; the pane says as much rather than implying the list is the whole difference.
    func isRowIncluded(_ entry: RowDiffEntry, in plan: DataComparePlan) -> Bool {
        entry.kind.isDifference && !plan.excludedRowKeys.contains(entry.keyIdentity)
    }

    func setRowIncluded(_ included: Bool, entry: RowDiffEntry, planId: String) {
        setRowsIncluded(included, entries: [entry], planId: planId)
    }

    func setRowsIncluded(_ included: Bool, entries: [RowDiffEntry], planId: String) {
        guard canChangeSetup, let index = dataPlans.firstIndex(where: { $0.id == planId }) else { return }
        let keys = entries.filter { $0.kind.isDifference }.map(\.keyIdentity)
        guard !keys.isEmpty else { return }
        if included {
            dataPlans[index].excludedRowKeys.subtract(keys)
        } else {
            dataPlans[index].excludedRowKeys.formUnion(keys)
        }
        invalidateScript()
    }

    var uncomparedIncludedPlans: [DataComparePlan] {
        dataPlans.filter { $0.isEnabled && $0.isComparable && $0.summary == nil }
    }

    var needsRecompare: Bool {
        guard mode == .data else { return false }
        return !uncomparedIncludedPlans.isEmpty
    }

    /// A script is only ever built from answers someone could have reviewed. An included table with
    /// no answer for its current scope used to be streamed and scripted anyway, so a table ticked
    /// after the comparison, or one whose key had just changed, reached Apply unseen.
    var dataScriptBlocker: String? {
        let unusable = dataPlans.filter { $0.isEnabled && !$0.isComparable }
        if !unusable.isEmpty {
            return String(
                format: String(localized: "Fix the settings for, or exclude, %@."),
                unusable.map(\.id).joined(separator: ", ")
            )
        }
        let uncompared = uncomparedIncludedPlans
        if !uncompared.isEmpty {
            return String(
                format: String(localized: "Compare again, or exclude the tables not compared yet: %@."),
                uncompared.map(\.id).joined(separator: ", ")
            )
        }
        let differing = dataPlans.contains {
            $0.isEnabled && $0.isComparable && ($0.summary?.differenceCount ?? 0) > 0
        }
        guard differing, selectedObjectCount == 0 else { return nil }
        return String(
            localized: "Every difference in the included tables is switched off in Options or excluded row by row."
        )
    }

    // MARK: - Pending scopes

    /// What a saved comparison or the remembered setup asked for, applied onto a freshly read
    /// table. A remembered key that no longer exists on both sides falls back to the table's own
    /// key rather than leaving the table uncomparable.
    func withPendingScope(_ plan: DataComparePlan) -> DataComparePlan {
        var result = plan
        if let pending = pendingTableScopes[plan.id] {
            var scope = pending
            /// An empty stored key is a choice the user made, not a missing value, so only a key
            /// naming a column this pair no longer shares falls back to the table's own.
            if scope.keyColumns.contains(where: { plan.column(named: $0) == nil }) {
                scope.keyColumns = plan.keyColumns
            }
            scope.restrictExclusions(to: plan.columnNames)
            result.scope = scope
        } else if !pendingLegacyExcludedColumns.isEmpty {
            for column in pendingLegacyExcludedColumns where plan.column(named: column) != nil {
                result.scope.setExcluded(true, column: column)
            }
        }
        guard result.scope != plan.scope else { return plan }
        result.summary = nil
        result.comparisonFailure = nil
        result.excludedRowKeys = []
        result.unavailableReason = DataComparePlan.unavailableReason(for: result)
        return result
    }

    // MARK: - Saved comparisons

    /// Every saved comparison, not only the ones matching the pair on screen.
    var savedProfiles: [CompareSyncProfile] {
        profileStorage.allProfiles()
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func saveProfile(named name: String) {
        guard let source, let target, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        profileStorage.save(
            currentSetup(named: name, source: source, target: target, includingSelection: true)
        )
    }

    /// Adopting a profile sets both endpoints, which is the whole point of having saved one.
    ///
    /// A scope whose connection has since been deleted is reported rather than silently dropped.
    @discardableResult
    func apply(_ profile: CompareSyncProfile) -> Bool {
        guard canLoadProfile else { return false }

        let connections = connectionsProvider()
        let resolvedSource = Self.endpoint(for: profile.source, in: connections)
        let resolvedTarget = Self.endpoint(for: profile.target, in: connections)

        mode = profile.mode
        includedKinds = profile.includedKinds.isEmpty ? [.table] : profile.includedKinds
        structureOptions = profile.structureOptions
        dataOptions = profile.dataOptions
        source = resolvedSource
        target = resolvedTarget
        resetComparison()
        pendingSelection = Set(profile.selectedObjects)
        pendingTableScopes = profile.tableScopes
        pendingLegacyExcludedColumns = profile.legacyExcludedColumns

        setupErrorMessage = resolvedSource == nil || resolvedTarget == nil
            ? String(format: String(localized: "%@ names a connection that no longer exists."), profile.name)
            : nil
        return true
    }

    var canLoadProfile: Bool {
        !isBusy
    }

    func deleteProfile(_ profile: CompareSyncProfile) {
        profileStorage.delete(profile)
    }

    // MARK: - Last setup

    /// Reopening the window lands on the comparison it last held. Nothing is compared and nothing
    /// is written by restoring it.
    func restore(_ setup: CompareSyncProfile, keepingSource pinnedSource: DatabaseEndpoint?) {
        let connections = connectionsProvider()
        mode = setup.mode
        includedKinds = setup.includedKinds.isEmpty ? [.table] : setup.includedKinds
        structureOptions = setup.structureOptions
        dataOptions = setup.dataOptions

        guard let pinnedSource else {
            source = Self.endpoint(for: setup.source, in: connections)
            target = Self.endpoint(for: setup.target, in: connections)
            pendingTableScopes = setup.tableScopes
            pendingLegacyExcludedColumns = setup.legacyExcludedColumns
            return
        }
        /// The window was opened against one connection, so that connection is the source. The
        /// remembered target, and the table scopes remembered with it, only come back when they
        /// were remembered against this same source.
        source = pinnedSource
        guard setup.source == pinnedSource.scope else { return }
        target = Self.endpoint(for: setup.target, in: connections)
        pendingTableScopes = setup.tableScopes
        pendingLegacyExcludedColumns = setup.legacyExcludedColumns
    }

    func rememberSetup() {
        guard let source, let target else { return }
        profileStorage.rememberSetup(
            currentSetup(named: "", source: source, target: target, includingSelection: false)
        )
    }

    private func currentSetup(
        named name: String,
        source: DatabaseEndpoint,
        target: DatabaseEndpoint,
        includingSelection: Bool
    ) -> CompareSyncProfile {
        CompareSyncProfile(
            name: name,
            source: source.scope,
            target: target.scope,
            mode: mode,
            includedKinds: includedKinds,
            structureOptions: structureOptions,
            dataOptions: dataOptions,
            selectedObjects: includingSelection ? selectedObjectIdentifiers : [],
            tableScopes: currentTableScopes,
            legacyExcludedColumns: hasLoadedDataPlans ? [] : pendingLegacyExcludedColumns
        )
    }

    /// Before the table list arrives the scopes on record are the ones still waiting to be applied,
    /// so writing the setup down in between does not throw them away.
    var currentTableScopes: [String: DataTableScope] {
        guard hasLoadedDataPlans else { return pendingTableScopes }
        return Dictionary(dataPlans.map { ($0.id, $0.scope) }, uniquingKeysWith: { first, _ in first })
    }

    private static func endpoint(
        for scope: DatabaseScope,
        in connections: [DatabaseConnection]
    ) -> DatabaseEndpoint? {
        guard let connection = connections.first(where: { $0.id == scope.connectionId }) else { return nil }
        return DatabaseEndpoint.from(connection: connection, database: scope.database, schema: scope.schema)
    }

    private var selectedObjectIdentifiers: [String] {
        switch mode {
        case .structure:
            return actions.filter { $0.value != .skip }.map { $0.key }.sorted()
        case .data:
            return dataPlans.filter { $0.isEnabled }.map { $0.id }.sorted()
        }
    }
}
