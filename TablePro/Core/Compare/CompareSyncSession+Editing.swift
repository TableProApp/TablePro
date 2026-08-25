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
        invalidateScript()
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
        invalidateScript()
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

    var savedProfiles: [CompareSyncProfile] {
        guard let source, let target else { return [] }
        return CompareSyncProfileStorage.shared.profiles(source: source.scope, target: target.scope, mode: mode)
    }

    func saveProfile(named name: String) {
        guard let source, let target, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let profile = CompareSyncProfile(
            name: name,
            source: source.scope,
            target: target.scope,
            mode: mode,
            includedKinds: includedKinds,
            structureOptions: structureOptions,
            dataOptions: dataOptions,
            selectedObjects: selectedObjectIdentifiers
        )
        CompareSyncProfileStorage.shared.save(profile)
    }

    func apply(_ profile: CompareSyncProfile) {
        mode = profile.mode
        includedKinds = profile.includedKinds.isEmpty ? [.table] : profile.includedKinds
        structureOptions = profile.structureOptions
        dataOptions = profile.dataOptions
        resetComparison()
        pendingSelection = Set(profile.selectedObjects)
    }

    func deleteProfile(_ profile: CompareSyncProfile) {
        CompareSyncProfileStorage.shared.delete(profile)
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
