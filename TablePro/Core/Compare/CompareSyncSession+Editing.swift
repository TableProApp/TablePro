//
//  CompareSyncSession+Editing.swift
//  TablePro
//
//  Editing a comparison after a first run: which columns identify a row, which
//  columns take part, which rows are excluded, and the saved setups.
//
//  Every edit here clears the affected result rather than adjusting it. A key
//  change means a different join, so the previous answer is not a stale version
//  of the new one, it is an answer to a different question.
//

import Foundation

internal extension CompareSyncSession {
    // MARK: - Key columns

    func setKeyColumns(_ columns: [String], for planId: String) {
        guard let index = dataPlans.firstIndex(where: { $0.id == planId }) else { return }
        dataPlans[index].keyColumns = columns
        dataPlans[index].summary = nil
        dataPlans[index].excludedRowKeys = []
        dataPlans[index].unavailableReason = DataComparePlan.unavailableReason(for: dataPlans[index])
        invalidateAnswer()
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

    func setPlanEnabled(_ enabled: Bool, for planId: String) {
        guard let index = dataPlans.firstIndex(where: { $0.id == planId }) else { return }
        dataPlans[index].isEnabled = enabled
        invalidateScript()
    }

    func setAllPlansEnabled(_ enabled: Bool) {
        for index in dataPlans.indices where dataPlans[index].isComparable {
            dataPlans[index].isEnabled = enabled
        }
        invalidateScript()
    }

    // MARK: - Comparison columns

    func isColumnCompared(_ column: String) -> Bool {
        !dataOptions.excludedFromComparison.contains { $0.caseInsensitiveCompare(column) == .orderedSame }
    }

    func toggleComparedColumn(_ column: String) {
        if let existing = dataOptions.excludedFromComparison
            .first(where: { $0.caseInsensitiveCompare(column) == .orderedSame }) {
            dataOptions.excludedFromComparison.remove(existing)
        } else {
            dataOptions.excludedFromComparison.insert(column)
        }
        clearDataSummaries()
    }

    /// A row exclusion is keyed on the row's identity, which only the key columns decide. Changing
    /// which columns take part in the comparison asks a different question of the same rows, so the
    /// answers are discarded and the exclusions are not: wiping them threw away every per-row
    /// decision in every table because one `updated_at` was unticked. `setKeyColumns` does clear
    /// them, because a new key really does mean different rows.
    func clearDataSummaries() {
        for index in dataPlans.indices {
            dataPlans[index].summary = nil
        }
        invalidateAnswer()
    }

    // MARK: - Row inclusion

    /// Row-level exclusion can only name a row the review pane actually showed. Past the retention
    /// cap the script is built from a fresh streamed pass, so an unseen row is included by
    /// definition; the pane says as much rather than implying the list is the whole difference.
    func isRowIncluded(_ entry: RowDiffEntry, in plan: DataComparePlan) -> Bool {
        !plan.excludedRowKeys.contains(entry.keyIdentity)
    }

    func setRowIncluded(_ included: Bool, entry: RowDiffEntry, planId: String) {
        guard let index = dataPlans.firstIndex(where: { $0.id == planId }) else { return }
        if included {
            dataPlans[index].excludedRowKeys.remove(entry.keyIdentity)
        } else {
            dataPlans[index].excludedRowKeys.insert(entry.keyIdentity)
        }
        invalidateScript()
    }

    var needsRecompare: Bool {
        guard mode == .data, !dataPlans.isEmpty else { return false }
        return dataPlans.contains { $0.isEnabled && $0.isComparable && $0.summary == nil }
    }

    // MARK: - Saved comparisons

    /// Every saved comparison, not only the ones matching the pair on screen.
    ///
    /// Filtering by the current source and target is what made the feature circular: a setup only
    /// listed once its own two endpoints had already been picked by hand, which is the work loading
    /// it exists to save. The scopes a profile stores are what it sets, so it is offered from a
    /// window that has chosen nothing.
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

    /// Adopting a profile sets both endpoints, which is the whole point of having saved one. It
    /// used to restore the mode and the options and leave the pickers untouched, so a load left the
    /// window pointed at whatever pair happened to be open.
    ///
    /// A scope whose connection has since been deleted is reported rather than silently dropped: a
    /// comparison that quietly loses its target would otherwise offer Compare against the endpoint
    /// still in the other picker.
    @discardableResult
    func apply(_ profile: CompareSyncProfile) -> Bool {
        /// A run in flight is writing to the target it captured, so swapping both endpoints under
        /// it would leave the window reporting one pair while the executor finishes against
        /// another. `canLoadProfile` is what the menu and the Load buttons validate against too.
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

        /// Written to the setup message rather than to `errorMessage`, which the option changes
        /// this load just made will clear through their own `onChange` reset.
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
    /// is written by restoring it: it is the two pickers, the mode and the options, which is the
    /// part of the work that was being repeated by hand every time.
    func restore(_ setup: CompareSyncProfile, keepingSource pinnedSource: DatabaseEndpoint?) {
        let connections = connectionsProvider()
        mode = setup.mode
        includedKinds = setup.includedKinds.isEmpty ? [.table] : setup.includedKinds
        structureOptions = setup.structureOptions
        dataOptions = setup.dataOptions

        guard let pinnedSource else {
            source = Self.endpoint(for: setup.source, in: connections)
            target = Self.endpoint(for: setup.target, in: connections)
            return
        }
        /// The window was opened against one connection, so that connection is the source. The
        /// remembered target only comes back when it was remembered against this same source,
        /// because a target is the side that gets written to and inheriting one from an unrelated
        /// comparison would arm the wrong database.
        source = pinnedSource
        /// The whole scope, not the connection alone. One connection reaches many databases and
        /// many schemas, and `DatabaseEndpoint.id` already treats those as different endpoints, so
        /// a connection match would hand database B the writable target remembered for database A.
        guard setup.source == pinnedSource.scope else { return }
        target = Self.endpoint(for: setup.target, in: connections)
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
            selectedObjects: includingSelection ? selectedObjectIdentifiers : []
        )
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
