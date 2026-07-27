//
//  CompareSyncSession+Editing.swift
//  TablePro
//
//  Editing the comparison setup after a first run: key columns, which columns
//  take part in the comparison, and saved profiles.
//

import Foundation

internal extension CompareSyncSession {
    // MARK: - Key columns

    func setKeyColumns(_ columns: [String], for planId: String) {
        guard let index = dataPlans.firstIndex(where: { $0.id == planId }) else { return }
        dataPlans[index].keyColumns = columns
        dataPlans[index].summary = nil
        dataPlans[index].unavailableReason = columns.isEmpty
            ? String(localized: "No primary key. Choose key columns to compare this table.")
            : nil
        invalidateGeneratedScript()
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

    func isKeyColumn(_ column: String, in plan: DataComparePlan) -> Bool {
        plan.keyColumns.contains { $0.caseInsensitiveCompare(column) == .orderedSame }
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

    func clearDataSummaries() {
        for index in dataPlans.indices {
            dataPlans[index].summary = nil
        }
        invalidateGeneratedScript()
    }

    var needsRecompare: Bool {
        guard mode == .data, !dataPlans.isEmpty else { return false }
        return dataPlans.contains { $0.isEnabled && $0.isComparable && $0.summary == nil }
    }

    private func invalidateGeneratedScript() {
        statements = []
        editedScript = nil
    }

    // MARK: - Profiles

    var savedProfiles: [CompareSyncProfile] {
        guard let source, let target else { return [] }
        return CompareSyncProfileStorage.shared.profiles(
            source: source.connectionId, target: target.connectionId, mode: mode
        )
    }

    func saveProfile(named name: String) {
        guard let source, let target, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let profile = CompareSyncProfile(
            name: name,
            sourceConnectionId: source.connectionId,
            targetConnectionId: target.connectionId,
            mode: mode,
            structureOptions: structureOptions,
            dataOptions: dataOptions,
            selectedTables: selectedTableIdentifiers
        )
        CompareSyncProfileStorage.shared.save(profile)
    }

    func apply(_ profile: CompareSyncProfile) {
        mode = profile.mode
        structureOptions = profile.structureOptions
        dataOptions = profile.dataOptions
        resetComparison()
        pendingSelectedTables = Set(profile.selectedTables)
    }

    func deleteProfile(_ profile: CompareSyncProfile) {
        CompareSyncProfileStorage.shared.delete(profile)
    }

    private var selectedTableIdentifiers: [String] {
        switch mode {
        case .structure:
            return tableActions.filter { $0.value != .skip }.map { $0.key }.sorted()
        case .data:
            return dataPlans.filter { $0.isEnabled }.map { $0.id }.sorted()
        }
    }
}
